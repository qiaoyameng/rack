# frozen_string_literal: true

require_relative 'helper'
require 'zlib'

separate_testing do
  require_relative '../lib/rack/static'
  require_relative '../lib/rack/lint'
  require_relative '../lib/rack/mock_request'
end

class DummyApp
  def call(env)
    [200, { "content-type" => "text/plain" }, ["Hello World"]]
  end
end

describe Rack::Static do
  DOCROOT = File.expand_path(File.dirname(__FILE__)) unless defined? DOCROOT

  def static(app, *args)
    Rack::Lint.new Rack::Static.new(app, *args)
  end

  root = File.expand_path(File.dirname(__FILE__))

  OPTIONS = { urls: ["/cgi"], root: root }
  CASCADE_OPTIONS = { urls: ["/cgi"], root: root, cascade: true }
  STATIC_OPTIONS = { urls: [""], root: "#{root}/static", index: 'index.html' }
  STATIC_URLS_OPTIONS = { urls: ["/static"], root: "#{root}", index: 'index.html' }
  HASH_OPTIONS = { urls: { "/cgi/sekret" => 'cgi/test' }, root: root }
  HASH_ROOT_OPTIONS = { urls: { "/" => "static/foo.html" }, root: root }
  GZIP_OPTIONS = { urls: ["/cgi"], root: root, gzip: true }
  PRECOMPRESSED_OPTIONS = { urls: ["/static"], root: root, precompressed: { 'br' => '.br', 'gzip' => '.gz' } }

  before do
  @request = Rack::MockRequest.new(static(DummyApp.new, OPTIONS))
  @cascade_request = Rack::MockRequest.new(static(DummyApp.new, CASCADE_OPTIONS))
  @static_request = Rack::MockRequest.new(static(DummyApp.new, STATIC_OPTIONS))
  @static_urls_request = Rack::MockRequest.new(static(DummyApp.new, STATIC_URLS_OPTIONS))
  @hash_request = Rack::MockRequest.new(static(DummyApp.new, HASH_OPTIONS))
  @hash_root_request = Rack::MockRequest.new(static(DummyApp.new, HASH_ROOT_OPTIONS))
  @gzip_request = Rack::MockRequest.new(static(DummyApp.new, GZIP_OPTIONS))
  @precompressed_request = Rack::MockRequest.new(static(DummyApp.new, PRECOMPRESSED_OPTIONS))
  @header_request = Rack::MockRequest.new(static(DummyApp.new, HEADER_OPTIONS))
  end

  it "serves files" do
    res = @request.get("/cgi/test")
    res.must_be :ok?
    res.body.must_match(/ruby/)
  end

  it "does not serve files outside :urls" do
    res = @request.get("/cgi/../#{File.basename(__FILE__)}")
    res.must_be :ok?
    res.body.must_equal "Hello World"
  end

  it "404s if url root is known but it can't find the file" do
    res = @request.get("/cgi/foo")
    res.must_be :not_found?
  end

  it "serves files when using :cascade option" do
    res = @cascade_request.get("/cgi/test")
    res.must_be :ok?
    res.body.must_match(/ruby/)
  end

  it "calls down the chain if if can't find the file when using the :cascade option" do
    res = @cascade_request.get("/cgi/foo")
    res.must_be :ok?
    res.body.must_equal "Hello World"
  end

  it "calls down the chain if url root is not known" do
    res = @request.get("/something/else")
    res.must_be :ok?
    res.body.must_equal "Hello World"
  end

  it "calls index file when requesting root in the given folder" do
    res = @static_request.get("/")
    res.must_be :ok?
    res.body.must_match(/index!/)

    res = @static_request.get("/other/")
    res.must_be :not_found?

    res = @static_request.get("/another/")
    res.must_be :ok?
    res.body.must_match(/another index!/)
  end

  it "does not call index file when requesting folder with unknown prefix" do
    res = @static_urls_request.get("/static/another/")
    res.must_be :ok?
    res.body.must_match(/index!/)

    res = @static_urls_request.get("/something/else/")
    res.must_be :ok?
    res.body.must_equal "Hello World"
  end

  it "doesn't call index file if :index option was omitted" do
    res = @request.get("/")
    res.body.must_equal "Hello World"
  end

  it "serves hidden files" do
    res = @hash_request.get("/cgi/sekret")
    res.must_be :ok?
    res.body.must_match(/ruby/)
  end

  it "calls down the chain if the URI is not specified" do
    res = @hash_request.get("/something/else")
    res.must_be :ok?
    res.body.must_equal "Hello World"
  end

  it "allows the root URI to be configured via hash options" do
    res = @hash_root_request.get("/")
    res.must_be :ok?
    res.body.must_match(/foo.html!/)
  end

  it "serves gzipped files if client accepts gzip encoding and gzip files are present" do
    res = @gzip_request.get("/cgi/test", 'HTTP_ACCEPT_ENCODING' => 'deflate, gzip')
    res.must_be :ok?
    res.headers['content-encoding'].must_equal 'gzip'
    res.headers['content-type'].must_equal 'text/plain'
    Zlib::GzipReader.wrap(StringIO.new(res.body), &:read).must_match(/ruby/)
  end

  it "serves regular files if client accepts gzip encoding and gzip files are not present" do
    res = @gzip_request.get("/cgi/rackup_stub.rb", 'HTTP_ACCEPT_ENCODING' => 'deflate, gzip')
    res.must_be :ok?
    res.headers['content-encoding'].must_be_nil
    res.headers['content-type'].must_equal 'text/x-script.ruby'
    res.body.must_match(/ruby/)
  end

  it "serves regular files if client does not accept gzip encoding" do
    res = @gzip_request.get("/cgi/test")
    res.must_be :ok?
    res.headers['content-encoding'].must_be_nil
    res.headers['content-type'].must_equal 'text/plain'
    res.body.must_match(/ruby/)
  end

  it "returns 304 if gzipped file isn't modified since last serve" do
    path = File.join(DOCROOT, "/cgi/test")
    res = @gzip_request.get("/cgi/test", 'HTTP_IF_MODIFIED_SINCE' => File.mtime(path).httpdate)
    res.status.must_equal 304
    res.body.must_be :empty?
    res.headers['content-encoding'].must_be_nil
    res.headers['content-type'].must_be_nil
  end

  it "return 304 if gzipped file isn't modified since last serve" do
    path = File.join(DOCROOT, "/cgi/test")
    res = @gzip_request.get("/cgi/test", 'HTTP_IF_MODIFIED_SINCE' => File.mtime(path+'.gz').httpdate, 'HTTP_ACCEPT_ENCODING' => 'deflate, gzip')

    res.status.must_equal 304
    res.body.must_be :empty?
  end

  it "supports serving fixed cache-control (legacy option)" do
    opts = OPTIONS.merge(cache_control: 'public')
    request = Rack::MockRequest.new(static(DummyApp.new, opts))
    res = request.get("/cgi/test")
    res.must_be :ok?
    res.headers['cache-control'].must_equal 'public'
  end

  HEADER_OPTIONS = { urls: ["/cgi"], root: root, header_rules: [
    [:all, { 'cache-control' => 'public, max-age=100' }],
    [:fonts, { 'cache-control' => 'public, max-age=200' }],
    [%w(png jpg), { 'cache-control' => 'public, max-age=300' }],
    ['/cgi/assets/folder/', { 'cache-control' => 'public, max-age=400' }],
    ['cgi/assets/javascripts', { 'cache-control' => 'public, max-age=500' }],
    [/\.(css|erb)\z/, { 'cache-control' => 'public, max-age=600' }],
    [false, { 'cache-control' => 'public, max-age=600' }]
  ] }

  it "supports header rule :all" do
    # Headers for all files via :all shortcut
    res = @header_request.get('/cgi/assets/index.html')
    res.must_be :ok?
    res.headers['cache-control'].must_equal 'public, max-age=100'
  end

  it "supports header rule :fonts" do
    # Headers for web fonts via :fonts shortcut
    res = @header_request.get('/cgi/assets/fonts/font.eot')
    res.must_be :ok?
    res.headers['cache-control'].must_equal 'public, max-age=200'
  end

  it "supports file extension header rules provided as an Array" do
    # Headers for file extensions via array
    res = @header_request.get('/cgi/assets/images/image.png')
    res.must_be :ok?
    res.headers['cache-control'].must_equal 'public, max-age=300'
  end

  it "supports folder rules provided as a String" do
    # Headers for files in folder via string
    res = @header_request.get('/cgi/assets/folder/test.js')
    res.must_be :ok?
    res.headers['cache-control'].must_equal 'public, max-age=400'
  end

  it "supports folder header rules provided as a String not starting with a slash" do
    res = @header_request.get('/cgi/assets/javascripts/app.js')
    res.must_be :ok?
    res.headers['cache-control'].must_equal 'public, max-age=500'
  end

  it "supports flexible header rules provided as Regexp" do
    # Flexible Headers via Regexp
    res = @header_request.get('/cgi/assets/stylesheets/app.css')
    res.must_be :ok?
    res.headers['cache-control'].must_equal 'public, max-age=600'
  end

  it "prioritizes header rules over fixed cache-control setting (legacy option)" do
    opts = OPTIONS.merge(
      cache_control: 'public, max-age=24',
      header_rules: [
        [:all, { 'cache-control' => 'public, max-age=42' }]
      ])

    request = Rack::MockRequest.new(static(DummyApp.new, opts))
    res = request.get("/cgi/test")
    res.must_be :ok?
    res.headers['cache-control'].must_equal 'public, max-age=42'
  end

  it "applies :fonts header rules to URL-encoded paths" do
    res = @header_request.get('/cgi/assets/fonts/font%2Eeot')
    res.must_be :ok?
    res.headers['cache-control'].must_equal 'public, max-age=200'
  end

  it "applies Array header rules to URL-encoded paths" do
    res = @header_request.get('/cgi/assets/images/image%2Epng')
    res.must_be :ok?
    res.headers['cache-control'].must_equal 'public, max-age=300'
  end

  it "applies Regexp header rules to URL-encoded paths" do
    res = @header_request.get('/cgi/assets/stylesheets/app%2Ecss')
    res.must_be :ok?
    res.headers['cache-control'].must_equal 'public, max-age=600'
  end

  it "escapes Array rule entries when building regexp" do
    opts = OPTIONS.merge(header_rules: [
      [['p.g'], { 'cache-control' => 'public, max-age=999' }]
    ])
    request = Rack::MockRequest.new(static(DummyApp.new, opts))
    # "p.g" should not match "png" since the dot must be literal
    res = request.get('/cgi/assets/images/image.png')
    res.must_be :ok?
    res.headers['cache-control'].must_be_nil
  end

  it "not allow directory traversal via root prefix bypass" do
    Dir.mktmpdir do |dir|
      root = File.join(dir, "root")
      outside = "#{root}_test"
      FileUtils.mkdir_p(root)
      FileUtils.mkdir_p(outside)
      FileUtils.touch(File.join(outside, "test.txt"))

      app = Rack::Static.new(proc { |env| [403, {}, ""] }, root: dir, urls: ["/root"])
      res = Rack::MockRequest.new(app).get("/root_test/test.txt")

      res.must_be :forbidden?
    end
  end

  it "expands the root path upon the middleware initialization" do
    relative_path = STATIC_OPTIONS[:root].sub("#{Dir.pwd}/", '')
    opts = { urls: [""], root: relative_path, index: 'index.html' }
    request = Rack::MockRequest.new(static(DummyApp.new, opts))
    Dir.chdir '..' do
      res = request.get("")
      res.must_be :ok?
      res.body.must_match(/index!/)
    end
  end

  NEGOTIATE_TXT = File.join(DOCROOT, 'static/negotiate.txt')
  NEGOTIATE_GZ = File.join(DOCROOT, 'static/negotiate.txt.gz')
  NEGOTIATE_BR = File.join(DOCROOT, 'static/negotiate.txt.br')

  it "serves the identity representation when no Accept-Encoding header is sent" do
    res = @precompressed_request.get("/static/negotiate.txt")
    res.must_be :ok?
    res.headers['content-encoding'].must_be_nil
    res.headers['vary'].must_equal 'Accept-Encoding'
    res.body.must_equal File.binread(NEGOTIATE_TXT)
  end

  it "serves the precompressed representation with the highest quality value" do
    res = @precompressed_request.get("/static/negotiate.txt", 'HTTP_ACCEPT_ENCODING' => 'gzip;q=1, br;q=0.5')
    res.must_be :ok?
    res.headers['content-encoding'].must_equal 'gzip'
    res.headers['content-type'].must_equal 'text/plain'
    res.headers['content-length'].must_equal File.size(NEGOTIATE_GZ).to_s
    res.headers['last-modified'].must_equal File.mtime(NEGOTIATE_GZ).httpdate
    Zlib::GzipReader.wrap(StringIO.new(res.body), &:read).must_equal "gzip representation of negotiate.txt\n"
  end

  it "serves the brotli representation when the client prefers it" do
    res = @precompressed_request.get("/static/negotiate.txt", 'HTTP_ACCEPT_ENCODING' => 'br;q=1, gzip;q=0.5')
    res.must_be :ok?
    res.headers['content-encoding'].must_equal 'br'
    res.headers['content-type'].must_equal 'text/plain'
    res.headers['content-length'].must_equal File.size(NEGOTIATE_BR).to_s
    res.body.must_equal File.binread(NEGOTIATE_BR)
  end

  it "breaks quality value ties using the server preference order" do
    res = @precompressed_request.get("/static/negotiate.txt", 'HTTP_ACCEPT_ENCODING' => 'gzip, br')
    res.must_be :ok?
    res.headers['content-encoding'].must_equal 'br'
  end

  it "does not let a wildcard override an explicit q=0" do
    res = @precompressed_request.get("/static/negotiate.txt", 'HTTP_ACCEPT_ENCODING' => 'br;q=0, *;q=1')
    res.must_be :ok?
    res.headers['content-encoding'].must_equal 'gzip'
  end

  it "serves the identity representation when it is the best acceptable representation" do
    res = @precompressed_request.get("/static/negotiate.txt", 'HTTP_ACCEPT_ENCODING' => 'gzip;q=0.5, br;q=0.5')
    res.must_be :ok?
    res.headers['content-encoding'].must_be_nil
    res.body.must_equal File.binread(NEGOTIATE_TXT)
  end

  it "serves a precompressed representation when identity is forbidden" do
    res = @precompressed_request.get("/static/negotiate.txt", 'HTTP_ACCEPT_ENCODING' => 'identity;q=0, gzip;q=1')
    res.must_be :ok?
    res.headers['content-encoding'].must_equal 'gzip'
  end

  it "returns 406 when identity is forbidden and no precompressed representation is acceptable" do
    res = @precompressed_request.get("/static/negotiate.txt", 'HTTP_ACCEPT_ENCODING' => 'identity;q=0, deflate;q=1')
    res.status.must_equal 406
    res.headers['vary'].must_equal 'Accept-Encoding'
  end

  it "returns 406 when a wildcard forbids all representations" do
    res = @precompressed_request.get("/static/negotiate.txt", 'HTTP_ACCEPT_ENCODING' => '*;q=0')
    res.status.must_equal 406
  end

  it "returns 406 when identity is forbidden and precompressed files do not exist" do
    res = @precompressed_request.get("/static/foo.html", 'HTTP_ACCEPT_ENCODING' => 'identity;q=0, gzip;q=1')
    res.status.must_equal 406
  end

  it "falls back to the identity representation when precompressed files do not exist" do
    res = @precompressed_request.get("/static/foo.html", 'HTTP_ACCEPT_ENCODING' => 'gzip, br')
    res.must_be :ok?
    res.headers['content-encoding'].must_be_nil
    res.body.must_match(/foo.html!/)
  end

  it "falls back to the next acceptable representation when the preferred one is missing" do
    res = @precompressed_request.get("/static/gzip_only.txt", 'HTTP_ACCEPT_ENCODING' => 'br;q=1, gzip;q=0.5, identity;q=0.1')
    res.must_be :ok?
    res.headers['content-encoding'].must_equal 'gzip'
    Zlib::GzipReader.wrap(StringIO.new(res.body), &:read).must_equal "gzip representation of gzip_only.txt\n"
  end

  it "supports HEAD requests against the selected representation" do
    res = @precompressed_request.head("/static/negotiate.txt", 'HTTP_ACCEPT_ENCODING' => 'gzip')
    res.must_be :ok?
    res.headers['content-encoding'].must_equal 'gzip'
    res.headers['content-length'].must_equal File.size(NEGOTIATE_GZ).to_s
    res.body.must_be :empty?
  end

  it "applies byte ranges to the selected representation" do
    res = @precompressed_request.get("/static/negotiate.txt",
      'HTTP_ACCEPT_ENCODING' => 'gzip', 'HTTP_RANGE' => 'bytes=0-3')
    res.status.must_equal 206
    res.headers['content-encoding'].must_equal 'gzip'
    res.headers['content-range'].must_equal "bytes 0-3/#{File.size(NEGOTIATE_GZ)}"
    res.body.must_equal File.binread(NEGOTIATE_GZ, 4)
  end

  it "revalidates conditional requests against the selected representation" do
    File.utime(File.atime(NEGOTIATE_TXT), Time.at(1_600_000_000), NEGOTIATE_TXT)
    File.utime(File.atime(NEGOTIATE_GZ), Time.at(1_700_000_000), NEGOTIATE_GZ)

    res = @precompressed_request.get("/static/negotiate.txt",
      'HTTP_ACCEPT_ENCODING' => 'gzip',
      'HTTP_IF_MODIFIED_SINCE' => File.mtime(NEGOTIATE_GZ).httpdate)
    res.status.must_equal 304
    res.body.must_be :empty?

    res = @precompressed_request.get("/static/negotiate.txt",
      'HTTP_ACCEPT_ENCODING' => 'gzip',
      'HTTP_IF_MODIFIED_SINCE' => File.mtime(NEGOTIATE_TXT).httpdate)
    res.must_be :ok?
    res.headers['content-encoding'].must_equal 'gzip'
  end

  it "merges Accept-Encoding into an existing Vary header instead of overwriting it" do
    opts = PRECOMPRESSED_OPTIONS.merge(header_rules: [[:all, { 'vary' => 'Cookie' }]])
    request = Rack::MockRequest.new(static(DummyApp.new, opts))
    res = request.get("/static/negotiate.txt", 'HTTP_ACCEPT_ENCODING' => 'gzip')
    res.must_be :ok?
    res.headers['vary'].must_equal 'Cookie, Accept-Encoding'
  end

  it "supports the :precompressed option given as an array of encoding names" do
    opts = PRECOMPRESSED_OPTIONS.merge(precompressed: %w[gzip br])
    request = Rack::MockRequest.new(static(DummyApp.new, opts))
    res = request.get("/static/negotiate.txt", 'HTTP_ACCEPT_ENCODING' => 'gzip, br')
    res.must_be :ok?
    res.headers['content-encoding'].must_equal 'gzip'
  end

  it "restores the original PATH_INFO after serving a precompressed file" do
    app = Rack::Static.new(DummyApp.new, PRECOMPRESSED_OPTIONS)
    env = Rack::MockRequest.env_for('/static/negotiate.txt', 'HTTP_ACCEPT_ENCODING' => 'gzip')
    app.call(env)
    env['PATH_INFO'].must_equal '/static/negotiate.txt'
  end

  it "restores the original PATH_INFO after hash path mapping" do
    app = Rack::Static.new(DummyApp.new,
      urls: { "/" => "static/negotiate.txt" }, root: DOCROOT, precompressed: %w[gzip br])
    env = Rack::MockRequest.env_for('/', 'HTTP_ACCEPT_ENCODING' => 'gzip')
    status, headers, _body = app.call(env)
    status.must_equal 200
    headers['content-encoding'].must_equal 'gzip'
    env['PATH_INFO'].must_equal '/'
  end

  it "restores the original PATH_INFO after directory index mapping" do
    app = Rack::Static.new(DummyApp.new,
      urls: [""], root: "#{DOCROOT}/static", index: 'index.html', precompressed: %w[gzip br])
    env = Rack::MockRequest.env_for('/', 'HTTP_ACCEPT_ENCODING' => 'gzip')
    app.call(env)
    env['PATH_INFO'].must_equal '/'
  end

  it "restores the original PATH_INFO when cascading to the app" do
    app = Rack::Static.new(
      ->(env) { [200, { 'content-type' => 'text/plain' }, [env['PATH_INFO']]] },
      PRECOMPRESSED_OPTIONS.merge(cascade: true))
    res = Rack::MockRequest.new(app).get('/static/missing.txt', 'HTTP_ACCEPT_ENCODING' => 'gzip')
    res.must_be :ok?
    res.body.must_equal '/static/missing.txt'
  end

  it "restores the original PATH_INFO when the file server raises" do
    app = Rack::Static.new(DummyApp.new, PRECOMPRESSED_OPTIONS)
    failing = Object.new
    def failing.call(env); raise "boom"; end
    app.instance_variable_set(:@file_server, failing)
    env = Rack::MockRequest.env_for('/static/negotiate.txt', 'HTTP_ACCEPT_ENCODING' => 'gzip')
    assert_raises(RuntimeError) { app.call(env) }
    env['PATH_INFO'].must_equal '/static/negotiate.txt'
  end
end
