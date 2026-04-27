# lib/substack_api/client/base.rb
require 'selenium-webdriver'
require 'logger'
require 'yaml'
require 'json'
require 'fileutils'
require 'net/http'
require 'uri'

module Substack
  class Client
    # = Base Module
    #
    # The Base module provides authentication functionality for the Substack API client.
    # It handles logging in with email/password using Selenium WebDriver and manages
    # cookie storage and loading.
    #
    # == Authentication Flow
    #
    # 1. Try to load cookies from disk if a cookies path is provided
    # 2. If no cookies exist or loading fails, log in with email/password if provided
    # 3. Save the session cookies for future use
    #
    module Base
      # Default path for storing cookies in the user's home directory
      DEFAULT_COOKIES_PATH = File.join(Dir.home, '.substack_cookies.yml')
      
      # Initialize the client with authentication credentials
      #
      # @param email [String, nil] Substack account email
      # @param password [String, nil] Substack account password
      # @param cookies_path [String, nil] Path to store/load session cookies
      # @param debug [Boolean] Whether to output debug logs
      def initialize(email: nil, password: nil, cookies_path: nil, debug: false)
        @cookies_path = cookies_path || DEFAULT_COOKIES_PATH
        @session = {}
        @logger = Logger.new($stdout)
        @logger.level = debug ? Logger::DEBUG : Logger::WARN

        if cookies_path && File.exist?(cookies_path)
          load_cookies(cookies_path)
        elsif email && password
          login(email, password)
        else
          @logger.warn "No authentication provided. Some API features will be unavailable."
        end
      end

      # Log in to Substack using Selenium WebDriver
      #
      # This method opens a headless Chrome browser, navigates to the Substack login page,
      # enters the provided credentials, and extracts session cookies upon successful login.
      #
      # @param email [String] Substack account email
      # @param password [String] Substack account password
      # @param headless [Boolean] Whether to run browser in headless mode (default: true)
      #   Set to false to allow manual CAPTCHA solving
      # @param wait_for_manual_captcha [Integer] Seconds to wait for manual CAPTCHA solving
      #   when headless is false (default: 120)
      # @raise [CaptchaRequiredError] If CAPTCHA is detected and headless is true
      # @raise [RuntimeError] If login fails
      def login(email, password, headless: true, wait_for_manual_captcha: 120)
        # Skip actual login in test mode
        if ENV['SUBSTACK_TEST_MODE'] == 'true'
          @logger.info "Running in test mode, skipping actual login"
          @session = {"substack.sid" => "test_session_id", "csrf-token" => "test_csrf_token"}
          return
        end
        
        @logger.info "Authenticating with Substack using Selenium..."
        options = Selenium::WebDriver::Chrome::Options.new
        options.add_argument('--headless') if headless
        options.add_argument('--start-maximized')
        options.add_argument('--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')
        options.add_argument('--disable-blink-features=AutomationControlled')
        options.add_argument('--disable-extensions')
        options.add_argument('--no-sandbox')
        options.add_argument('--disable-dev-shm-usage')
      
        begin
          driver = nil
          # Try to find chromedriver in different locations
          if File.exist?('/usr/local/bin/chromedriver')
            service = Selenium::WebDriver::Chrome::Service.new(path: '/usr/local/bin/chromedriver')
            driver = Selenium::WebDriver.for :chrome, service: service, options: options
          else
            # Fall back to letting Selenium find chromedriver automatically
            driver = Selenium::WebDriver.for :chrome, options: options
          end
      
          begin
            driver.get('https://substack.com/sign-in')
            wait = Selenium::WebDriver::Wait.new(timeout: 20)
            
            # Check for CAPTCHA before attempting login
            captcha_type = detect_captcha(driver)
            if captcha_type
              handle_captcha(driver, captcha_type, headless, wait_for_manual_captcha)
            end
        
            email_field = wait.until { driver.find_element(name: 'email') }
            email_field.send_keys(email)
        
            sign_in_button = wait.until { driver.find_element(link_text: 'Sign in with password') }
            sign_in_button.click
        
            password_field = wait.until { driver.find_element(name: 'password') }
            password_field.send_keys(password, :return)
        
            # Wait for login to complete and check for post-login CAPTCHA
            sleep 3
            
            # Check again for CAPTCHA after submitting credentials
            captcha_type = detect_captcha(driver)
            if captcha_type
              handle_captcha(driver, captcha_type, headless, wait_for_manual_captcha)
            end
            
            # Wait for successful login indication
            wait_for_login_success(driver, wait)
        
            @logger.info "Login successful, extracting cookies..."
            browser_cookies = driver.manage.all_cookies
            
            @session = {}
            browser_cookies.each do |cookie|
              @session[cookie[:name] || cookie['name']] = cookie[:value] || cookie['value']
            end
            
            # Validate session
            unless @session['substack.sid']
              raise Substack::AuthenticationError, "Login failed: session cookie not found"
            end
            
            save_cookies(@cookies_path)
            @logger.info "Cookies saved to '#{@cookies_path}'"
          ensure
            driver.quit
          end
        rescue Substack::CaptchaRequiredError
          raise # Re-raise CAPTCHA errors
        rescue Substack::AuthenticationError
          raise # Re-raise authentication errors
        rescue => e
          @logger.error "Login failed: #{e.message}"
          raise Substack::AuthenticationError, "Failed to authenticate with Substack: #{e.message}"
        end
      end
      
      # Detect CAPTCHA on the current page
      #
      # @param driver [Selenium::WebDriver] The Selenium WebDriver instance
      # @return [String, nil] The type of CAPTCHA detected, or nil if none found
      def detect_captcha(driver)
        Substack::CaptchaRequiredError.detect_captcha(driver)
      end
      
      # Handle CAPTCHA detection
      #
      # Attempts automatic solving via 2captcha if TWOCAPTCHA_API_KEY is set in the
      # environment. Falls back to raising (headless) or waiting for manual input
      # (non-headless) if 2captcha is not configured or fails.
      #
      # @param driver [Selenium::WebDriver] The Selenium WebDriver instance
      # @param captcha_type [String] The type of CAPTCHA detected
      # @param headless [Boolean] Whether running in headless mode
      # @param wait_time [Integer] Seconds to wait for manual solving
      # @raise [CaptchaRequiredError] If solving fails and no fallback is available
      def handle_captcha(driver, captcha_type, headless, wait_time)
        @logger.warn "CAPTCHA detected: #{captcha_type}"

        if ENV['TWOCAPTCHA_API_KEY']
          begin
            solve_with_2captcha(driver, captcha_type)
            return
          rescue => e
            @logger.warn "2captcha solving failed: #{e.message}. Falling back..."
          end
        end

        if headless
          raise Substack::CaptchaRequiredError.new(
            "CAPTCHA verification required. Set TWOCAPTCHA_API_KEY or retry with headless: false.",
            captcha_type: captcha_type,
            can_retry: true
          )
        end

        # Non-headless fallback: wait for user to solve manually
        @logger.info "Please solve the CAPTCHA in the browser window. Waiting up to #{wait_time} seconds..."

        start_time = current_time
        while current_time - start_time < wait_time
          current_captcha = detect_captcha(driver)
          unless current_captcha
            @logger.info "CAPTCHA solved successfully"
            return
          end
          captcha_sleep(2)
        end

        raise Substack::CaptchaRequiredError.new(
          "Timed out waiting for CAPTCHA to be solved",
          captcha_type: captcha_type,
          can_retry: false
        )
      end

      # Automatically solve a CAPTCHA using the 2captcha service
      #
      # Requires TWOCAPTCHA_API_KEY to be set in the environment.
      # Supports hcaptcha, recaptcha, and cloudflare (Turnstile) types.
      #
      # @param driver [Selenium::WebDriver] The Selenium WebDriver instance
      # @param captcha_type [String] The type of CAPTCHA ('hcaptcha', 'recaptcha', 'cloudflare')
      # @raise [RuntimeError] If the site key cannot be found or the API call fails
      def solve_with_2captcha(driver, captcha_type)
        api_key = ENV['TWOCAPTCHA_API_KEY']
        page_url = driver.current_url

        site_key = extract_captcha_site_key(driver, captcha_type)
        raise "Could not extract site key for #{captcha_type} on #{page_url}" unless site_key

        @logger.info "Submitting #{captcha_type} CAPTCHA to 2captcha (site key: #{site_key[0..7]}...)"

        captcha_id = submit_to_2captcha(
          build_2captcha_params(captcha_type, site_key, page_url, api_key)
        )

        @logger.info "Polling 2captcha for solution (ID: #{captcha_id})..."
        token = poll_2captcha_solution(captcha_id, api_key)

        inject_captcha_token(driver, captcha_type, token)
        captcha_sleep(2)

        @logger.info "CAPTCHA solved via 2captcha"
      end

      private

      # Extract the site key from the CAPTCHA widget on the current page
      #
      # @param driver [Selenium::WebDriver]
      # @param captcha_type [String]
      # @return [String, nil]
      def extract_captcha_site_key(driver, captcha_type)
        case captcha_type.to_s
        when 'hcaptcha'
          ['.h-captcha', '[data-hcaptcha-widget-id]'].each do |sel|
            el = driver.find_element(css: sel) rescue nil
            key = el&.[]('data-sitekey')
            return key if key
          end
          iframe = driver.find_element(css: 'iframe[src*="hcaptcha"]') rescue nil
          if iframe
            match = (iframe['src'] || '').match(/[?&]sitekey=([^&]+)/)
            return URI.decode_www_form_component(match[1]) if match
          end
        when 'recaptcha'
          el = driver.find_element(css: '.g-recaptcha') rescue nil
          key = el&.[]('data-sitekey')
          return key if key
          iframe = driver.find_element(css: 'iframe[src*="recaptcha"]') rescue nil
          if iframe
            match = (iframe['src'] || '').match(/[?&]k=([^&]+)/)
            return match[1] if match
          end
        when 'cloudflare'
          el = driver.find_element(css: '.cf-turnstile, [data-sitekey]') rescue nil
          return el&.[]('data-sitekey')
        end
        nil
      end

      # Build the parameter hash for the 2captcha submission endpoint
      #
      # @param captcha_type [String]
      # @param site_key [String]
      # @param page_url [String]
      # @param api_key [String]
      # @return [Hash]
      def build_2captcha_params(captcha_type, site_key, page_url, api_key)
        base = { key: api_key, pageurl: page_url, json: '1' }
        case captcha_type.to_s
        when 'hcaptcha'   then base.merge(method: 'hcaptcha',      sitekey:   site_key)
        when 'recaptcha'  then base.merge(method: 'userrecaptcha', googlekey: site_key)
        when 'cloudflare' then base.merge(method: 'turnstile',     sitekey:   site_key)
        else raise "Unsupported CAPTCHA type for 2captcha: #{captcha_type}"
        end
      end

      # Submit a CAPTCHA task to 2captcha and return the task ID
      #
      # @param params [Hash] Parameters for the in.php endpoint
      # @return [String] The captcha task ID
      # @raise [RuntimeError] On API error
      def submit_to_2captcha(params)
        uri = URI('https://2captcha.com/in.php')
        response = Net::HTTP.post_form(uri, params.transform_keys(&:to_s))
        result = JSON.parse(response.body)
        raise "2captcha submission error: #{result['error_text'] || result['request']}" if result['status'].to_i != 1
        result['request']
      end

      # Poll the 2captcha result endpoint until the solution is ready
      #
      # @param captcha_id [String] Task ID returned by submit_to_2captcha
      # @param api_key [String]
      # @param timeout [Integer] Maximum seconds to wait (default 120)
      # @return [String] The solution token
      # @raise [RuntimeError] On timeout or API error
      def poll_2captcha_solution(captcha_id, api_key, timeout: 120)
        uri = URI('https://2captcha.com/res.php')
        deadline = current_time + timeout

        captcha_sleep(15)

        loop do
          uri.query = URI.encode_www_form(key: api_key, action: 'get', id: captcha_id, json: '1')
          result = JSON.parse(Net::HTTP.get(uri))

          return result['request'] if result['status'].to_i == 1

          raise "2captcha timed out after #{timeout}s" if current_time > deadline
          raise "2captcha error: #{result['request']}" unless result['request'] == 'CAPCHA_NOT_READY'

          captcha_sleep(5)
        end
      end

      # Inject the 2captcha solution token into the page
      #
      # @param driver [Selenium::WebDriver]
      # @param captcha_type [String]
      # @param token [String] Solution token from 2captcha
      def inject_captcha_token(driver, captcha_type, token)
        case captcha_type.to_s
        when 'hcaptcha'
          driver.execute_script(<<~JS, token)
            const token = arguments[0];
            document.querySelectorAll('[name="h-captcha-response"]').forEach(el => {
              el.value = token;
              el.dispatchEvent(new Event('change', { bubbles: true }));
            });
            if (window.hcaptcha) {
              try { window.hcaptcha.execute(); } catch(e) {}
            }
          JS
        when 'recaptcha'
          driver.execute_script(<<~JS, token)
            const token = arguments[0];
            const el = document.getElementById('g-recaptcha-response');
            if (el) { el.style.display = ''; el.value = token; }
            const clients = window.___grecaptcha_cfg?.clients || {};
            Object.values(clients).forEach(c => {
              try {
                const cb = c.L?.L?.callback;
                if (typeof cb === 'function') cb(token);
              } catch(e) {}
            });
          JS
        when 'cloudflare'
          driver.execute_script(<<~JS, token)
            document.querySelectorAll('[name="cf-turnstile-response"]').forEach(el => {
              el.value = arguments[0];
            });
          JS
          # Turnstile validates server-side; submit the form to proceed
          driver.execute_script("document.querySelector('form')?.submit()")
        end
      end

      public
      
      # Get current time - separate method for testability
      # @return [Time] Current time
      def current_time
        Time.now
      end
      
      # Sleep helper for CAPTCHA handling - separate method for testability
      # @param seconds [Integer] Seconds to sleep
      def captcha_sleep(seconds)
        sleep(seconds)
      end
      
      # Wait for successful login indication
      #
      # @param driver [Selenium::WebDriver] The Selenium WebDriver instance
      # @param wait [Selenium::WebDriver::Wait] Wait object with timeout
      def wait_for_login_success(driver, wait)
        # Wait for URL to change away from sign-in or for user avatar to appear
        begin
          wait.until do
            !driver.current_url.include?('/sign-in') ||
            driver.find_elements(css: '[data-testid="user-icon"], .user-avatar, .user-menu').any?
          end
        rescue Selenium::WebDriver::Error::TimeoutError
          # Timeout is okay, we'll check cookies anyway
          @logger.warn "Login redirect timeout - checking cookies anyway"
        end
      end

      # Save session cookies to a file
      #
      # @param path [String] Path where cookies will be saved
      def save_cookies(path = @cookies_path)
        FileUtils.mkdir_p(File.dirname(path)) unless File.directory?(File.dirname(path))
        File.write(path, @session.to_yaml)
        @logger.debug "Saved cookies to #{path}"
      end

      # Load session cookies from a file
      #
      # Supports both YAML (preferred) and JSON formats for backward compatibility.
      #
      # @param path [String] Path to load cookies from
      # @raise [LoadError] If cookies cannot be loaded
      def load_cookies(path)
        @logger.debug "Loading cookies from #{path}"
        cookies_data = File.read(path)
        
        # Try parsing as YAML first (preferred format)
        begin
          @session = YAML.load(cookies_data)
        rescue => e
          # Fallback to JSON if YAML parsing fails
          @logger.debug "YAML parsing failed, trying JSON: #{e.message}"
          begin
            raw_cookies = JSON.parse(cookies_data)
            
            # Handle the legacy format where cookies were stored as array
            if raw_cookies.is_a?(Array)
              @session = raw_cookies.each_with_object({}) do |cookie, hash|
                hash[cookie['name']] = cookie['value']
              end
            else
              @session = raw_cookies
            end
          rescue
            raise LoadError, "Failed to load cookies from #{path}"
          end
        end
      end
    end
  end
end
