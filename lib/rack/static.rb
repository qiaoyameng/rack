# frozen_string_literal: true

require_relative 'constants'
require_relative 'files'
require_relative 'mime'

module Rack

  # The Rack::Static middleware intercepts requests for static files
  # (javascript files, images, stylesheets, etc) based on the url prefixes or
  # route mappings passed in the options, and serves them using a Rack::Files
  # object. This allows a Rack stack to serve both static and dynamic content.
  #
  # Examples:
  #
  # Serve all requests beginning with /media from the "media" folder located
  # in the current directory (ie media/*):
  #
  #     use Rack::Static, :urls => ["/media"]
  #
  # Same as previous, but instead of returning 404 for missing files under
  # /media, call the next middleware:
  #
  #     use Rack::Static, :urls => ["/media"], :cascade => true
  #
  # Serve all requests beginning with /css or /images from the folder "public"
  # in the current directory (ie public/css/* and public/images/*):
  #
  #     use Rack::Static, :urls => ["/css", "/images"], :root => "public"
  #
  # Serve all requests to / with "index.html" from the folder "public" in the
  # current directory (ie public/index.html):
  #
  #     use Rack::Static, :urls => {"/" => 'index.html'}, :root => 'public'
  #
  # Serve all requests normally from the folder "public" in the current
  # directory but uses index.html as default route for "/"
  #
  #     use Rack::Static, :urls => [""], :root => 'public', :index =>
  #     'index.html'
  #
  # Serve precompressed representations of files when the client accepts
  # the related content encoding. The :precompressed option maps content
  # encodings to the file extension of the precompressed representation:
  #
  #     use Rack::Static, :urls => ["/media"],
  #         :precompressed => { 'br' => '.br', 'gzip' => '.gz' }
  #
  # When the extension is simply the encoding name prefixed with a dot,
  # an array of encoding names can be used instead:
  #
  #     use Rack::Static, :urls => ["/media"], :precompressed => %w[br gzip]
  #
  # The representation served is selected based on the quality values of
  # the request's Accept-Encoding header, with ties broken by the server
  # preference order given in the :precompressed option. Only
  # representations that actually exist on disk are considered, and the
  # identity (uncompressed) representation is used as a fallback unless
  # the client explicitly forbids it (in which case a 406 response is
  # returned if no precompressed representation is available). The
  # legacy :gzip => true option is equivalent to
  # :precompressed => %w[gzip].
  #
  # Set custom HTTP Headers for based on rules:
  #
  #     use Rack::Static, :root => 'public',
  #         :header_rules => [
  #           [rule, {header_field => content, header_field => content}],
  #           [rule, {header_field => content}]
  #         ]
  #
  #  Rules for selecting files:
  #
  #  1) All files
  #     Provide the :all symbol
  #     :all => Matches every file
  #
  #  2) Folders
  #     Provide the folder path as a string
  #     '/folder' or '/folder/subfolder' => Matches files in a certain folder
  #
  #  3) File Extensions
  #     Provide the file extensions as an array
  #     ['css', 'js'] or %w(css js) => Matches files ending in .css or .js
  #
  #  4) Regular Expressions / Regexp
  #     Provide a regular expression
  #     %r{\.(?:css|js)\z} => Matches files ending in .css or .js
  #     /\.(?:eot|ttf|otf|woff2|woff|svg)\z/ => Matches files ending in
  #       the most common web font formats (.eot, .ttf, .otf, .woff2, .woff, .svg)
  #       Note: This Regexp is available as a shortcut, using the :fonts rule
  #
  #  5) Font Shortcut
  #     Provide the :fonts symbol
  #     :fonts => Uses the Regexp rule stated right above to match all common web font endings
  #
  #  Rule Ordering:
  #    Rules are applied in the order that they are provided.
  #    List rather general rules above special ones.
  #
  #  Complete example use case including HTTP header rules:
  #
  #     use Rack::Static, :root => 'public',
  #         :header_rules => [
  #           # Cache all static files in public caches (e.g. Rack::Cache)
  #           #  as well as in the browser
  #           [:all, {'cache-control' => 'public, max-age=31536000'}],
  #
  #           # Provide web fonts with cross-origin access-control-headers
  #           #  Firefox requires this when serving assets using a Content Delivery Network
  #           [:fonts, {'access-control-allow-origin' => '*'}]
  #         ]
  #
  class Static
    def initialize(app, options = {})
      @app = app
      @urls = options[:urls] || ["/favicon.ico"]
      if @urls.kind_of?(Array)
        @urls = @urls.map { |url| [url, url.end_with?('/') ? url : "#{url}/".freeze].freeze }.freeze
      end
      @index = options[:index]
      @precompressed = normalize_precompressed(options)
      @cascade = options[:cascade]
      root = options[:root] || Dir.pwd

      # HTTP Headers
      @header_rules = options[:header_rules] || []
      # Allow for legacy :cache_control option while prioritizing global header_rules setting
      @header_rules.unshift([:all, { CACHE_CONTROL => options[:cache_control] }]) if options[:cache_control]

      @file_server = Rack::Files.new(root)
    end

    def add_index_root?(path)
      @index && route_file(path) && path.end_with?('/')
    end

    def overwrite_file_path(path)
      @urls.kind_of?(Hash) && @urls.key?(path) || add_index_root?(path)
    end

    def route_file(path)
      @urls.kind_of?(Array) && @urls.any? { |url, url_slash| path == url || path.start_with?(url_slash) }
    end

    def can_serve(path)
      route_file(path) || overwrite_file_path(path)
    end

    def call(env)
      path = env[PATH_INFO]
      actual_path = Utils.clean_path_info(Utils.unescape_path(path))

      if can_serve(actual_path)
        original_path_info = env[PATH_INFO]
        begin
          if overwrite_file_path(path)
            env[PATH_INFO] = (add_index_root?(path) ? path + @index : @urls[path])
          end

          response = nil
          if @precompressed && env['HTTP_ACCEPT_ENCODING']
            response = precompressed_response(env)
          end

          path = env[PATH_INFO]
          response ||= @file_server.call(env)

          if @cascade && response[0] == 404
            return @app.call(env)
          end

          headers = response[1]
          applicable_rules(path).each do |rule, new_headers|
            new_headers.each { |field, content| headers[field] = content }
          end

          merge_vary(headers) if @precompressed

          response
        ensure
          env[PATH_INFO] = original_path_info
        end
      else
        @app.call(env)
      end
    end

    # Normalize the :precompressed option (and the legacy :gzip option)
    # into an ordered list of [encoding, extension] pairs, where the
    # order defines the server preference when the client assigns equal
    # quality values to multiple representations.
    def normalize_precompressed(options)
      precompressed = options[:precompressed]
      precompressed = { 'gzip' => '.gz' } if precompressed.nil? && options[:gzip]

      pairs =
        case precompressed
        when Hash
          precompressed.map { |encoding, extension| [encoding.to_s, extension.to_s] }
        when Array
          precompressed.map { |encoding| [encoding.to_s, ".#{encoding}"] }
        when nil
          return nil
        else
          raise ArgumentError, ":precompressed must be a Hash or an Array"
        end

      pairs.map! { |encoding, extension| [encoding.downcase, extension] }
      pairs.reject! { |encoding, _| encoding == 'identity' || encoding == '*' }
      pairs.freeze
    end

    # Attempt to serve a precompressed representation of the requested
    # file, selected based on the quality values of the request's
    # Accept-Encoding header and the server preference order given by
    # the :precompressed option. Only representations that exist on
    # disk are served. Returns nil if the identity representation
    # should be served by the regular file server, a 406 response if
    # the client forbids the identity representation and no acceptable
    # precompressed representation exists, or the selected response.
    def precompressed_response(env)
      accepted = {}
      Utils.q_values(env['HTTP_ACCEPT_ENCODING']).each do |encoding, quality|
        accepted[encoding.downcase] = quality
      end

      candidates = @precompressed.each_with_index.map do |(encoding, extension), index|
        [encoding, extension, encoding_quality(accepted, encoding), index]
      end
      identity_quality = encoding_quality(accepted, 'identity')
      candidates << [nil, nil, identity_quality, candidates.size]
      candidates.select! { |candidate| candidate[2] > 0 }
      candidates.sort_by! { |_, _, quality, index| [-quality, index] }

      return not_acceptable_response if candidates.empty?

      path = env[PATH_INFO]
      not_found = nil

      candidates.each do |encoding, extension, _quality, _index|
        begin
          env[PATH_INFO] = "#{path}#{extension}" if extension
          response = @file_server.call(env)
        ensure
          env[PATH_INFO] = path
        end

        if response[0] == 404
          not_found ||= response
          next
        end

        if extension && (response[0] == 200 || response[0] == 206)
          # The selected file holds the precompressed bytes of the
          # original resource, so report the content type of the
          # original resource along with the content encoding.
          response[1][CONTENT_TYPE] = Mime.mime_type(::File.extname(path), 'text/plain')
          response[1]['content-encoding'] = encoding
        end

        return response
      end

      identity_quality > 0 ? not_found : not_acceptable_response
    end

    # The quality value the client assigned to the given content
    # encoding. An explicit entry (including q=0) always takes
    # precedence over a wildcard. The identity representation is
    # acceptable by default unless explicitly forbidden.
    def encoding_quality(accepted, encoding)
      if accepted.key?(encoding)
        accepted[encoding]
      elsif accepted.key?('*')
        accepted['*']
      else
        encoding == 'identity' ? 1.0 : 0.0
      end
    end

    def not_acceptable_response
      body = "Not Acceptable\n"
      [406, { CONTENT_TYPE => 'text/plain', CONTENT_LENGTH => body.bytesize.to_s }, [body]]
    end

    # Merge Accept-Encoding into the Vary response header without
    # overwriting any values already present.
    def merge_vary(headers)
      vary = headers['vary']
      values = vary ? vary.split(',').map { |value| value.strip.downcase } : []
      unless values.include?('*') || values.include?('accept-encoding')
        headers['vary'] = vary.nil? || vary.empty? ? 'Accept-Encoding' : "#{vary}, Accept-Encoding"
      end
    end

    # Convert HTTP header rules to HTTP headers
    def applicable_rules(path)
      path = ::Rack::Utils.unescape_path(path)

      @header_rules.find_all do |rule, new_headers|
        case rule
        when :all
          true
        when :fonts
          /\.(?:ttf|otf|eot|woff2|woff|svg)\z/.match?(path)
        when String
          path.start_with?(rule) || path.start_with?('/' + rule)
        when Array
          /\.#{Regexp.union(rule)}\z/.match?(path)
        when Regexp
          rule.match?(path)
        else
          false
        end
      end
    end

  end
end
