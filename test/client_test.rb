require_relative 'test_helper'

class ClientTest < Minitest::Test
  def setup
    # Use stub authentication methods from test_client.rb
    @client = Substack::Client.new(email: 'test@example.com', password: 'password')
  end


  def test_determine_primary_publication_url_custom_domain
    @client.stubs(:get_user_profile).returns({
      "primaryPublication" => {
        "custom_domain" => "example.com"
      }
    })
    
    url = @client.send(:determine_primary_publication_url)
    assert_equal "https://example.com/api/v1", url
  end

  def test_determine_primary_publication_url_subdomain
    @client.stubs(:get_user_profile).returns({
      "primaryPublication" => {
        "subdomain" => "example"
      }
    })
    
    url = @client.send(:determine_primary_publication_url)
    assert_equal "https://example.substack.com/api/v1", url
  end

  def test_construct_publication_url_with_custom_domain
    publication = { "custom_domain" => "example.com" }
    url = @client.send(:construct_publication_url, publication)
    assert_equal "https://example.com", url
  end

  def test_construct_publication_url_with_subdomain
    publication = { "subdomain" => "example" }
    url = @client.send(:construct_publication_url, publication)
    assert_equal "https://example.substack.com", url
  end

  def test_retry_with_backoff_success_first_try
    # The block should be called exactly once and succeed
    counter = 0
    
    result = @client.send(:retry_with_backoff) do
      counter += 1
      "success"
    end
    
    assert_equal 1, counter
    assert_equal "success", result
  end

  def test_retry_with_backoff_success_after_retries
    # The block should retry and eventually succeed
    counter = 0
    
    @client.expects(:sleep).with(1).once
    @client.expects(:sleep).with(2).once
    
    result = @client.send(:retry_with_backoff, max_retries: 3, delay: 1) do
      counter += 1
      if counter < 3
        raise RuntimeError, "Temporary failure"
      else
        "success after retries"
      end
    end
    
    assert_equal 3, counter
    assert_equal "success after retries", result
  end

  def test_retry_with_backoff_max_retries_exceeded
    # The block should fail after max retries
    counter = 0
    
    @client.expects(:sleep).with(1).once
    @client.expects(:sleep).with(2).once
    
    assert_raises(RuntimeError) do
      @client.send(:retry_with_backoff, max_retries: 3, delay: 1) do
        counter += 1
        raise RuntimeError, "Persistent failure"
      end
    end
    
    assert_equal 3, counter
  end

  def test_determine_primary_publication_url_nil_custom_domain
    client = Substack::Client.new(email: 'test@example.com', password: 'password')
    
    # Mock get_user_profile to return a profile with a primary publication
    client.expects(:get_user_profile).returns({
      "primaryPublication" => {
        "subdomain" => "testblog",
        "custom_domain" => nil
      }
    })
    
    # Call the method
    url = client.send(:determine_primary_publication_url)
    
    # Verify the correct URL was constructed
    assert_equal "https://testblog.substack.com/api/v1", url
  end
  
  def test_determine_primary_publication_url_has_custom_domain
    client = Substack::Client.new(email: 'test@example.com', password: 'password')
    
    # Mock get_user_profile to return a profile with a primary publication with custom domain
    client.expects(:get_user_profile).returns({
      "primaryPublication" => {
        "subdomain" => "testblog",
        "custom_domain" => "blog.example.com"
      }
    })
    
    # Call the method
    url = client.send(:determine_primary_publication_url)
    
    # Verify the correct URL was constructed
    assert_equal "https://blog.example.com/api/v1", url
  end
  def test_initialize
    assert_instance_of Substack::Client, @client
  end

  def test_get_user_id
    @client.stubs(:get_user_profile).returns({"id" => 123})
    user_id = @client.get_user_id
    assert_equal 123, user_id
  end

  def test_get_user_id_no_profile
    @client.stubs(:get_user_profile).returns({})
    assert_nil @client.get_user_id
  end

  def test_get_user_id_nil_profile
    @client.stubs(:get_user_profile).returns(nil)
    assert_nil @client.get_user_id
  end

  def test_post_draft
    # Stub out all the methods we'd call
    post = Substack::Post.new(title: 'Test Title', subtitle: 'Test Subtitle', user_id: 123)
    post.paragraph('This is a test paragraph.')
    
    @client.stubs(:determine_primary_publication_url).returns("https://test.substack.com/api/v1")
    @client.stubs(:request).returns({"id" => "draft123"})
    
    result = @client.post_draft(post.get_draft)
    assert_equal "draft123", result["id"]
  end
  
  def test_post_draft_with_publication
    post = Substack::Post.new(title: 'Test Title', subtitle: 'Test Subtitle', user_id: 123)
    post.paragraph('This is a test paragraph.')
    
    @client.stubs(:request).returns({"id" => "draft456"})
    
    result = @client.post_draft(post.get_draft, publication_url: "https://custom.substack.com")
    assert_equal "draft456", result["id"]
  end
  
  def test_request_get
    # Make the request method accessible for testing
    @client.instance_eval do
      def public_request(url, method: :get, json: nil, **qs)
        request(method, url, json: json, **qs)
      end
    end
    
    mock_response = mock('response')
    mock_response.stubs(:body).returns('{"success":true}')
    mock_response.stubs(:status).returns(200)
    mock_response.stubs(:[]).with("content-encoding").returns(nil)
    
    # Create a mock connection
    mock_connection = mock('connection')
    mock_connection.expects(:get).returns(mock_response)
    
    # Stub Faraday.new to return our mock connection
    Faraday.stubs(:new).returns(mock_connection)
    
    result = @client.public_request("https://test.substack.com/api/endpoint")
    assert_equal({"success" => true}, result)
  end
  
  def test_request_post
    # Make the request method accessible for testing
    @client.instance_eval do
      def public_request(url, method: :get, json: nil, **qs)
        request(method, url, json: json, **qs)
      end
    end
    
    mock_response = mock('response')
    mock_response.stubs(:body).returns('{"success":true}')
    mock_response.stubs(:status).returns(200)
    mock_response.stubs(:[]).with("content-encoding").returns(nil)
    
    # Create a mock connection that expects post with JSON
    mock_connection = mock('connection')
    mock_connection.expects(:post).returns(mock_response)
    
    # Stub Faraday.new to return our mock connection
    Faraday.stubs(:new).returns(mock_connection)
    
    result = @client.public_request("https://test.substack.com/api/endpoint", method: :post, json: {key: "value"})
    assert_equal({"success" => true}, result)
  end
  
  def test_request_with_error
    # Make the request method accessible for testing
    @client.instance_eval do
      def public_request(url, method: :get, json: nil, **qs)
        request(method, url, json: json, **qs)
      end
      
      # Override handle_response to raise a ValidationError for this test
      def handle_response(response)
        if response.status == 422
          raise Substack::ValidationError.new("Validation error", 
            status: 422, 
            errors: [{"msg" => "Invalid data"}]
          )
        else
          super
        end
      end
    end
    
    mock_response = mock('response')
    mock_response.stubs(:body).returns('{"errors":[{"msg":"Invalid data"}]}')
    mock_response.stubs(:status).returns(422)
    mock_response.stubs(:[]).with("content-encoding").returns(nil)
    
    # Create a mock connection
    mock_connection = mock('connection')
    mock_connection.expects(:post).returns(mock_response)
    
    # Stub Faraday.new to return our mock connection
    Faraday.stubs(:new).returns(mock_connection)
    
    assert_raises(Substack::ValidationError) do
      @client.public_request("https://test.substack.com/api/endpoint", method: :post)
    end
  end
  
end