require 'yaml'
require 'openssl'
require 'base64'
require_relative '../acquia-http-hmac'

module Acquia
  module HTTPHmac
    class RackAuthenticate
      def initialize(app, options)
        @password_storage = options[:password_storage]
        @realm = options[:realm]
        @nonce_checker = options[:nonce_checker]
        @app = app
      end

      def call(env)
        auth_header = env['HTTP_AUTHORIZATION'].to_s
        return unauthorized if auth_header.empty?

        attributes = Acquia::HTTPHmac::Auth.parse_auth_header(auth_header)
        return denied('Invalid nonce') unless @nonce_checker.valid?(attributes[:id], attributes[:nonce])
        mac = message_authenticator(attributes)
        args = args_for_authenticator(env)
        return denied('Invalid credentials') unless mac && mac.request_authenticated?(attributes, args)

        return denied('Invalid body') unless valid_body?(env)

        # Pass the id to later stages
        env['ACQUIA_AUTHENTICATED_ID'] = attributes[:id]
        (status, headers, resp_body) = @app.call(env)
        sign_response(status, headers, resp_body, attributes, mac)
      end

      private

      def unauthorized
        [ 401,
          {
            'Content-Type' => 'text/plain',
            'Content-Length' => '0',
            'WWW-Authenticate' => 'acquia-http-hmac realm="'+ @realm +'"'
          },
          []
        ]
      end

      def denied(message)
        [ 403,
          { 'Content-Type' => 'text/plain' },
          [message]
        ]
      end

      def message_authenticator(attributes)
        mac = nil
        if @password_storage.valid?(attributes[:id])
          mac = Acquia::HTTPHmac::Auth.new(@realm, @password_storage.password(attributes[:id]))
        end
        mac
      end

      def args_for_authenticator(env)
        request = Rack::Request.new(env)
        {
          host: request.host_with_port,
          query_string: request.query_string,
          http_method: request.request_method,
          path_info: request.path_info,
          content_type: request.content_type,
          body_hash: env['HTTP_X_ACQUIA_CONTENT_SHA256'],
        }
      end

      def valid_body?(env)
        request = Rack::Request.new(env)
        if ['GET', 'HEAD'].include?(request.request_method)
          # No body to validate
          true
        else
          body = request.body.gets   # read the incoming request IO stream
          body_hash = Base64.encode64(OpenSSL::Digest::SHA256.digest(body)).strip
          body_hash == env['HTTP_X_ACQUIA_CONTENT_SHA256']
        end
      end

      # Add a hmac signature over the resonse body.
      #
      # @param [Int] status
      # @param [Hash] headers
      # @param [Enumerable] resp_body
      # @param [Hash] attributes
      # @param [Acquia::HTTPHmac::Auth] mac
      #
      # @return Array
      def sign_response(status, headers, resp_body, attributes, mac)
        final_body = ''
        # Rack defines the response body as implementing #each
        resp_body.each { |part| final_body << part }
        pragma = []
        # Preserve existing headers
        if headers['Pragma']
          pragma << headers['Pragma']
        end
        # Use the request nonce to sign the response.
        pragma << 'hmac_digest=' + mac.signature(attributes[:nonce] + final_body) + ';'
        headers['Pragma'] = pragma.join(', ')
        # Nobody should be changing or caching this response.
        headers['Cache-Control'] = 'no-transform, no-cache, no-store, private, max-age=0'
        [status, headers, [final_body]]
      end

    end

    class FilePasswordStorage

      def initialize(filename)
        @creds = {}
        if File.exist?(filename)
          @creds = YAML.safe_load(File.read(filename))
        end
      end

      def valid?(id)
        !!@creds[id]
      end

      def password(id)
        fail('Invalid id') unless @creds[id] && @creds[id]['password']
        @creds[id]['password']
      end

      def data(id)
        fail('Invalid id') unless @creds[id]
        @creds[id]
      end

      def ids
        @creds.keys
      end
    end

    class NoopNonceChecker
      def valid?(id, nonce)
        true
      end
    end

    class MemoryNonceChecker
      def initialize
        @seen = {}
      end

      def valid?(id, nonce)
        @seen[id] ||= {}
        valid = !@seen[id][nonce]
        @seen[id][nonce] = Time.now.to_i
        valid
      end
    end
  end
end

