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
  # Serve precompressed representations of the files when the client accepts
  # them, selecting from files that actually exist according to the request's
  # Accept-Encoding quality values and the server preference order (br is
  # preferred over gzip below). No on-the-fly compression is performed:
  #
  #     use Rack::Static, :urls => [""], :root => 'public',
  #         :precompressed_versions => {'br' => '.br', 'gzip' => '.gz'}
  #
  # The legacy :gzip => true option is equivalent to
  # :precompressed_versions => {'gzip' => '.gz'}.
  #
  class Static
    # Sentinel content coding used for the uncompressed resource.
    IDENTITY_ENCODING = 'identity'.freeze

    def initialize(app, options = {})
      @app = app
      @urls = options[:urls] || ["/favicon.ico"]
      if @urls.kind_of?(Array)
        @urls = @urls.map { |url| [url, url.end_with?('/') ? url : "#{url}/".freeze].freeze }.freeze
      end
      @index = options[:index]
      @cascade = options[:cascade]
      root = options[:root] || Dir.pwd

      # Mapping of content-coding name to the file extension of the
      # precompressed representation (e.g. {'gzip' => '.gz', 'br' => '.br'}).
      precompressed_versions = options[:precompressed_versions]
      if options[:gzip]
        precompressed_versions ||= {}
        precompressed_versions['gzip'] ||= '.gz'
      end
      if precompressed_versions
        @precompressed_versions = precompressed_versions.map do |encoding, extension|
          extension = ".#{extension}" unless extension.start_with?('.')
          [encoding.to_s, extension]
        end.to_h.freeze
      end

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
      original_path = env[PATH_INFO]
      actual_path = Utils.clean_path_info(Utils.unescape_path(original_path))

      return @app.call(env) unless can_serve(actual_path)

      begin
        if overwrite_file_path(original_path)
          env[PATH_INFO] = (add_index_root?(original_path) ? original_path + @index : @urls[original_path])
        end

        path = env[PATH_INFO]
        response = serve_representation(env, path)

        if @cascade && response[0] == 404
          env[PATH_INFO] = original_path
          return @app.call(env)
        end

        headers = response[1]
        applicable_rules(path).each do |rule, new_headers|
          new_headers.each { |field, content| headers[field] = content }
        end
        merge_vary(headers) if negotiated?(env)

        response
      ensure
        env[PATH_INFO] = original_path
      end
    end

    private

    # Serve the best available representation of the resource located at
    # +path+, taking the client's Accept-Encoding header into account when
    # precompressed versions are configured.
    #
    # The Content-Type is always derived from the original resource, while
    # Content-Length, Last-Modified, Range handling and conditional request
    # handling refer to the bytes of the representation actually selected.
    def serve_representation(env, path)
      negotiated = negotiated?(env)
      resource_exists = false

      if negotiated
        available = available_encodings(path)
        resource_exists = !available.empty?

        # When at least one representation exists, an acceptable coding
        # must be chosen; otherwise the resource itself is missing and the
        # regular 404 flow (including cascade) applies.
        encoding = resource_exists ?
          best_encoding(available, Rack::Request.new(env).accept_encoding) :
          IDENTITY_ENCODING
      else
        encoding = IDENTITY_ENCODING
      end

      return not_acceptable if negotiated && resource_exists && encoding.nil?

      if encoding == IDENTITY_ENCODING
        response = @file_server.call(env)
        return response unless negotiated
      else
        env[PATH_INFO] = "#{path}#{@precompressed_versions[encoding]}"
        response = @file_server.call(env)
      end

      merge_vary(response[1])
      return not_acceptable if negotiated && resource_exists && response[0] == 404

      decorate_representation(response, encoding, path)
      response
    end

    # Set the headers describing the representation that was selected:
    # Content-Type from the original resource, Content-Encoding for a
    # precompressed representation. Only applied to responses that actually
    # transfer (or revalidate against) the representation's bytes.
    def decorate_representation(response, encoding, path)
      case response[0]
      when 200, 206
        headers = response[1]
        if encoding == IDENTITY_ENCODING
          return
        elsif headers[CONTENT_LENGTH] == '0'
          # Rack::Files answers OPTIONS with an empty body; such a
          # response does not carry any encoded representation.
          return
        end

        if headers.key?(CONTENT_TYPE)
          headers[CONTENT_TYPE] = Mime.mime_type(::File.extname(path), 'text/plain') unless
            headers[CONTENT_TYPE].include?('multipart/byteranges')
        end
        headers['content-encoding'] = encoding
      when 304
        response[1]['content-encoding'] = encoding unless encoding == IDENTITY_ENCODING
      end
    end

    def negotiated?(env)
      @precompressed_versions && env.key?('HTTP_ACCEPT_ENCODING')
    end

    # List the content codings whose representation file exists on disk,
    # including identity when the original resource exists.
    def available_encodings(path)
      available = []
      available << IDENTITY_ENCODING if file_exists?(path)
      @precompressed_versions.each do |encoding, extension|
        available << encoding if precompressed_file?(path, extension)
      end
      available
    end

    # Select the best available content coding from the parsed
    # Accept-Encoding entries (each an [encoding, quality] pair).
    #
    # Unlike Rack::Utils.select_best_encoding this honors the RFC 7231
    # wildcard rules: encodings listed explicitly with q=0 keep being
    # forbidden even when the wildcard allows them, and the implicit
    # identity fallback is only used when identity has not been mentioned
    # explicitly.
    def best_encoding(available, accept_encoding)
      accept_encoding = accept_encoding.first(16)
      explicit = accept_encoding.map(&:first)
      wildcard_quality = nil
      accept_encoding.each do |encoding, quality|
        wildcard_quality = quality if encoding == '*'
      end

      candidates = available.map do |encoding|
        if (index = explicit.index(encoding))
          [encoding, accept_encoding[index][1], available.index(encoding)]
        elsif encoding == IDENTITY_ENCODING
          # RFC 7231 5.3.4: identity not listed explicitly is always
          # acceptable, but ranks below every wildcard match and is only
          # a last resort.
          quality = wildcard_quality || 0.001
          [encoding, quality, available.length]
        elsif wildcard_quality
          [encoding, wildcard_quality, available.index(encoding)]
        end
      end.compact

      candidate = candidates.min do |(_, q1, p1), (_, q2, p2)|
        if (q = (q2 <=> q1)).nonzero?
          q
        else
          p1 <=> p2
        end
      end

      return nil if candidate.nil? || candidate[1] == 0.0
      candidate[0]
    end

    # Resolve the on-disk location of a request path, following the same
    # path handling as Rack::Files.
    def disk_path(path)
      ::File.join(@file_server.root, Utils.clean_path_info(Utils.unescape_path(path)))
    end

    def file_exists?(path)
      candidate = disk_path(path)
      ::File.file?(candidate) && ::File.readable?(candidate)
    rescue SystemCallError
      false
    end

    def precompressed_file?(path, extension)
      file_exists?("#{path}#{extension}")
    end

    def not_acceptable
      body = "Not Acceptable\n"
      [
        406,
        {
          CONTENT_TYPE     => 'text/plain',
          CONTENT_LENGTH   => body.bytesize.to_s,
          'vary'           => 'Accept-Encoding'
        },
        [body]
      ]
    end

    # Add Accept-Encoding to the Vary header, preserving any values already
    # present instead of replacing them.
    def merge_vary(headers)
      vary = headers['vary'].to_s.split(',').map(&:strip)
      unless vary.include?('*') || vary.any? { |value| value.casecmp('accept-encoding').zero? }
        headers['vary'] = vary.push('Accept-Encoding').join(', ')
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
