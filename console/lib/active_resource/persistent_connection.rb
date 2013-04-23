require 'active_support/core_ext/benchmark'
require 'net/https'
require 'date'
require 'time'
require 'uri'
require 'net/http/persistent'

# Derived from ActiveResource::Connection
module ActiveResource
  # Class to handle connections to remote web services.
  # This class is used by ActiveResource::Base to interface with REST
  # services.
  class PersistentConnection

    HTTP_FORMAT_HEADER_NAMES = {  :get => 'Accept',
      :put => 'Content-Type',
      :post => 'Content-Type',
      :patch => 'Content-Type',
      :delete => 'Accept',
      :head => 'Accept'
    }

    class ServerRefusedConnection < Errno::ECONNREFUSED
      def initialize(site,path=nil)
        @site, @path = site, path
      end

      def message
        "Connection refused to #{@site}#{@path}"
      end
    end

    attr_reader :site, :user, :password, :auth_type, :timeout, :proxy, :ssl_options, :connection_name
    attr_accessor :format

    class << self
      def requests
        @@requests ||= []
      end
    end

    # Override to change the Persistent slot
    def connection_name
      @connection_name || 'active_resource'
    end

    # The +site+ parameter is required and will set the +site+
    # attribute to the URI for the remote resource service.
    def initialize(site, format = ActiveResource::Formats::XmlFormat)
      raise ArgumentError, 'Missing site URI' unless site
      @user = @password = nil
      @uri_parser = URI.const_defined?(:Parser) ? URI::Parser.new : URI
      self.site = site
      self.format = format
    end

    # Set URI for remote service.
    def site=(site)
      @site = site.is_a?(URI) ? site : @uri_parser.parse(site)
      @user = @uri_parser.unescape(@site.user) if @site.user
      @password = @uri_parser.unescape(@site.password) if @site.password
    end

    # Set the proxy for remote service.
    def proxy=(proxy)
      @proxy = proxy.is_a?(URI) ? proxy : @uri_parser.parse(proxy)
    end

    # Sets the user for remote service.
    def user=(user)
      @user = user
    end

    # Sets the password for remote service.
    def password=(password)
      @password = password
    end

    # Sets the auth type for remote service.
    def auth_type=(auth_type)
      @auth_type = legitimize_auth_type(auth_type)
    end

    # Sets the debug output stream for HTTP requests
    def debug_output=(debug_output)
      @debug_output = debug_output
    end

    [:idle_timeout, :read_timeout, :open_timeout, :timeout].each do |sym|
      define_method :"#{sym}=" do |value|
        instance_variable_set(:"@#{sym}", value)
      end
    end

    # Hash of options applied to Net::HTTP instance when +site+ protocol is 'https'.
    def ssl_options=(opts={})
      @ssl_options = opts
    end

    # Name for this group of requests, passed to Net::HTTP::Persistent
    def connection_name=(name)
      @connection_name = name
    end

    # Executes a GET request.
    # Used to get (find) resources.
    # Note; removed format.decode wrapper and .get method call
    def get(path, headers = {})
      with_auth { request(:get, path, build_request_headers(headers, :get, self.site.merge(path))) }
    end

    # Executes a DELETE request (see HTTP protocol documentation if unfamiliar).
    # Used to delete resources.
    def delete(path, headers = {})
      with_auth { request(:delete, path, build_request_headers(headers, :delete, self.site.merge(path))) }
    end

    # Executes a PUT request (see HTTP protocol documentation if unfamiliar).
    # Used to update resources.
    def put(path, body = '', headers = {})
      with_auth { request(:put, path, body.to_s, build_request_headers(headers, :put, self.site.merge(path))) }
    end

    # Executes a POST request.
    # Used to create new resources.
    def post(path, body = '', headers = {})
      with_auth { request(:post, path, body.to_s, build_request_headers(headers, :post, self.site.merge(path))) }
    end

    # Executes a PATCH request.
    # Used to create new resources.
    def patch(path, body = '', headers = {})
      with_auth { request(:patch, path, body.to_s, build_request_headers(headers, :patch, self.site.merge(path))) }
    end

    # Executes a HEAD request.
    # Used to obtain meta-information about resources, such as whether they exist and their size (via response headers).
    def head(path, headers = {})
      with_auth { request(:head, path, build_request_headers(headers, :head, self.site.merge(path))) }
    end

    private
      # Makes a request to the remote service.
      def request(method, path, *arguments)
        req = case method
          when :get
            req = Net::HTTP::Get.new path, arguments[0]
          when :head
            req = Net::HTTP::Head.new path, arguments[0]
          when :delete
            req = Net::HTTP::Delete.new path, arguments[0]
          when :put
            req = Net::HTTP::Put.new path, arguments[1]
            req.body = arguments[0]
            req
          when :patch
            req = Net::HTTP::Patch.new path, arguments[1]
            req.body = arguments[0]
            req
          when :post
            req = Net::HTTP::Post.new path, arguments[1]
            req.body = arguments[0]
            req
          else
            raise StandardError, "Method not recognized #{method}"
          end
        result = ActiveSupport::Notifications.instrument("request.active_resource") do |payload|
          payload[:method]      = method
          payload[:request_uri] = "#{site.scheme}://#{site.host}:#{site.port}#{path}"
          payload[:result] = http.request site, req
        end
        handle_response(result)
      rescue Timeout::Error => e
        raise TimeoutError.new(e.message)
      rescue OpenSSL::SSL::SSLError => e
        raise SSLError.new(e.message)
      rescue Net::HTTP::Persistent::Error => e
        raise ConnectionError.new(e.message)
      rescue Errno::ECONNREFUSED => e
        raise ServerRefusedConnection.new(site, req.path)
      end

      # Handles response and error codes from the remote service.
      def handle_response(response)
        case response.code.to_i
          when 301,302
            raise(Redirection.new(response))
          when 200...400
            response
          when 400
            raise(BadRequest.new(response))
          when 401
            raise(UnauthorizedAccess.new(response))
          when 403
            raise(ForbiddenAccess.new(response))
          when 404
            raise(ResourceNotFound.new(response))
          when 405
            raise(MethodNotAllowed.new(response))
          when 409
            raise(ResourceConflict.new(response))
          when 410
            raise(ResourceGone.new(response))
          when 422
            raise(ResourceInvalid.new(response))
          when 401...500
            raise(ClientError.new(response))
          when 503
            raise(ServerError.new(response, JSON.parse(response.body)['messages'][0]['text']))
          when 500...600
            raise(ServerError.new(response))
          else
            raise(ConnectionError.new(response, "Unknown response code: #{response.code}"))
        end
      end

      # Get or create Net::HTTP::Persistent instance for communication with the
      # remote service and resources.
      def http
        @http ||= configure_http(new_http)
      end

      def new_http
        http = Net::HTTP::Persistent.new connection_name
        http.proxy = @proxy if @proxy
        http
      end

      def configure_http(http)
        http = apply_ssl_options(http)

        # Net::HTTP timeouts default to 60 seconds.
        if @timeout
          http.open_timeout = @timeout
          http.read_timeout = @timeout
        end

        [:read_timeout, :open_timeout, :idle_timeout].each do |sym|
          http.send(:"#{sym}=", instance_variable_get(:"@#{sym}")) if instance_variable_get(:"@#{sym}")
        end

        http
      end

      def apply_ssl_options(http)
        return http unless @site.is_a?(URI::HTTPS)

        #http.ssl(true) #changed
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        return http unless defined?(@ssl_options)

        [:ca_path, :ca_file,
         :cert, :key, :cert_store, :ssl_timeout, :ssl_version,
         :verify_mode, :verify_callback, :verify_depth
        ].each do |sym|
          http.send(:"#{sym}=", @ssl_options[sym]) if @ssl_options[sym]
        end

        http
      end

      def default_header
        @default_header ||= {}
      end

      # Builds headers for request to remote service.
      def build_request_headers(headers, http_method, uri)
        authorization_header(http_method, uri).update(default_header).update(http_format_header(http_method)).update(headers)
      end

      def response_auth_header
        @response_auth_header ||= ""
      end

      def with_auth
        retried ||= false
        yield
      rescue UnauthorizedAccess => e
        raise if retried || auth_type != :digest
        @response_auth_header = e.response['WWW-Authenticate']
        retried = true
        retry
      end

      def authorization_header(http_method, uri)
        if @user || @password
          if auth_type == :digest
            { 'Authorization' => digest_auth_header(http_method, uri) }
          else
            { 'Authorization' => 'Basic ' + ["#{@user}:#{@password}"].pack('m').delete("\r\n") }
          end
        else
          {}
        end
      end

      def digest_auth_header(http_method, uri)
        params = extract_params_from_response

        ha1 = Digest::MD5.hexdigest("#{@user}:#{params['realm']}:#{@password}")
        ha2 = Digest::MD5.hexdigest("#{http_method.to_s.upcase}:#{uri.path}")

        params.merge!('cnonce' => client_nonce)
        request_digest = Digest::MD5.hexdigest([ha1, params['nonce'], "0", params['cnonce'], params['qop'], ha2].join(":"))
        "Digest #{auth_attributes_for(uri, request_digest, params)}"
      end

      def client_nonce
        Digest::MD5.hexdigest("%x" % (Time.now.to_i + rand(65535)))
      end

      def extract_params_from_response
        params = {}
        if response_auth_header =~ /^(\w+) (.*)/
          $2.gsub(/(\w+)="(.*?)"/) { params[$1] = $2 }
        end
        params
      end

      def auth_attributes_for(uri, request_digest, params)
        [
          %Q(username="#{@user}"),
          %Q(realm="#{params['realm']}"),
          %Q(qop="#{params['qop']}"),
          %Q(uri="#{uri.path}"),
          %Q(nonce="#{params['nonce']}"),
          %Q(nc="0"),
          %Q(cnonce="#{params['cnonce']}"),
          %Q(opaque="#{params['opaque']}"),
          %Q(response="#{request_digest}")].join(", ")
      end

      def http_format_header(http_method)
        {HTTP_FORMAT_HEADER_NAMES[http_method] => format.mime_type}
      end

      def legitimize_auth_type(auth_type)
        return :basic if auth_type.nil?
        auth_type = auth_type.to_sym
        [:basic, :digest].include?(auth_type) ? auth_type : :basic
      end
  end
end
