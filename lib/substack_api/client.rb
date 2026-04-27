# lib/substack_api/client.rb

require "selenium-webdriver"
require "json"
require "logger"
require "faraday"

# Client modules
require_relative "client/base"
require_relative "client/api"

module Substack
  # = Client Class
  #
  # The main client class for interacting with the Substack API. This class combines
  # the Base module for authentication and the API module for making API requests.
  #
  # == Example Usage
  #
  #   # Initialize with email/password
  #   client = Substack::Client.new(email: 'your@email.com', password: 'password')
  #
  #   # Or use previously saved cookies
  #   client = Substack::Client.new
  #
  #   # Get user profile
  #   profile = client.get_user_profile
  #
  #   # Post a draft
  #   post = Substack::Post.new(title: 'My Post', subtitle: 'Subtitle', user_id: client.get_user_id)
  #   post.paragraph('Content goes here')
  #   client.post_draft(post.get_draft)
  #
  # @see Substack::Post for creating post content
  # @see Substack::Client::API for API methods
  # @see Substack::Client::Base for authentication
  class Client
    include Base
    include API
    
    # @return [String] Base URL for the Substack API
    # @return [Hash] Session data including cookies
    # @return [String] Path to store cookies
    # @return [String] URL for the user's primary publication API
    attr_accessor :base_url, :session, :cookies_path, :publication_url

    # Initialize a new Substack client
    #
    # Note: This method is primarily defined in the Base module, but additional
    # parameters specific to the main Client class are documented here.
    #
    # @param email [String, nil] Substack account email
    # @param password [String, nil] Substack account password 
    # @param cookies_path [String, nil] Path to store/load session cookies
    # @param base_url [String, nil] Base URL for the Substack API
    # @param publication_url [String, nil] URL for a specific publication
    # @param debug [Boolean] Whether to output debug logs
    def initialize(email: nil, password: nil, cookies_path: nil, base_url: nil, publication_url: nil, debug: false)
      @base_url = base_url || "https://substack.com/api/v1"
      @cookies_path = cookies_path
      @session = {}
      @publication_url = publication_url
      @logger = Logger.new($stdout)
      @logger.level = debug ? Logger::DEBUG : Logger::WARN

      # Skip authentication in test mode
      if ENV['SUBSTACK_TEST_MODE'] == 'true'
        @logger.info "Running in test mode, skipping authentication"
        @session = {"substack.sid" => "test_session_id", "csrf-token" => "test_csrf_token"}
        return
      end

      if cookies_path && File.exist?(cookies_path)
        load_cookies(cookies_path)
      elsif email && password
        login(email, password)
      else
        raise ArgumentError, "Provide either cookies_path or email and password for authentication."
      end

      @publication_url ||= determine_primary_publication_url
    end

    # Get the current user's ID
    #
    # @return [Integer, nil] The user's ID or nil if not available
    def get_user_id
      profile = get_user_profile
      profile && profile["id"]
    end

    # Get the current user's profile information
    #
    # @return [Hash] The user's profile data
    def get_user_profile
      request(:get, "#{Endpoints::API}/user/profile/self")
    end

    # Post a draft to Substack
    #
    # @param draft [Hash] The draft post content (usually from Post#get_draft)
    # @param publication_url [String, nil] Optional custom publication URL
    # @return [Hash] The response from the API
    # @raise [Error] If posting fails
    def post_draft(draft, publication_url: nil)
      # Use provided publication URL or determine the primary one
      pub_url = publication_url || determine_primary_publication_url
      request(:post, "#{pub_url}/drafts", json: draft)
    end
    
    private
    
    # Determine the URL for the user's primary publication
    #
    # @return [String] The API URL for the user's primary publication
    def determine_primary_publication_url
      profile = get_user_profile
      primary_pub = profile["primaryPublication"]

      if primary_pub["custom_domain"]
        "https://#{primary_pub['custom_domain']}/api/v1"
      else
        "https://#{primary_pub['subdomain']}.substack.com/api/v1"
      end
    end
    
    # Construct a publication URL from publication data
    #
    # @param publication [Hash] Publication data containing domain information
    # @return [String] The publication URL
    def construct_publication_url(publication)
      if publication["custom_domain"]
        "https://#{publication['custom_domain']}"
      else
        "https://#{publication['subdomain']}.substack.com"
      end
    end
    
    # Retry a block of code with exponential backoff
    #
    # @param max_retries [Integer] Maximum number of retry attempts
    # @param delay [Integer] Initial delay in seconds, doubles with each retry
    # @yield The block to execute with retry logic
    # @raise [Exception] If the block fails after all retries
    def retry_with_backoff(max_retries: 3, delay: 1)
      attempts = 0
      begin
        attempts += 1
        @logger.debug "Attempt #{attempts} of #{max_retries}"
        yield
      rescue => e
        if attempts < max_retries
          sleep_time = delay * (2 ** (attempts - 1))
          @logger.debug "Error: #{e.message}. Retrying in #{sleep_time}s..."
          sleep(sleep_time)
          retry
        else
          @logger.error "Max retries (#{max_retries}) reached. Final error: #{e.message}"
          raise
        end
      end
    end
  end
end