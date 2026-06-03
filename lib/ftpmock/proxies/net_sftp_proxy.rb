# https://github.com/net-ssh/net-sftp
begin
  require 'net/sftp'
rescue LoadError
  nil
end

module Ftpmock
  class NetSftpProxy
    # Stubbers

    Real = begin
      Net::SFTP
    rescue NameError
      nil
    end

    # Captured before `on!` swaps Net::SFTP, so a real session can still be opened on a cache miss.
    RealSession = begin
      Net::SFTP::Session
    rescue NameError
      nil
    end

    # inspired by https://github.com/bblimke/webmock/blob/master/lib/webmock/http_lib_caches/net_http.rb
    def self.on!
      unless Real
        yield if block_given?
        return
      end

      Net.send(:remove_const, :SFTP)
      Net.const_set(:SFTP, self)
      if block_given?
        yield
        off!
      end
    end

    def self.off!
      return unless Real

      Net.send(:remove_const, :SFTP)
      Net.const_set(:SFTP, Real)
    end

    PORT = 22

    # Mirrors Net::SFTP.start(host, user, options = {}) { |sftp| ... }
    # https://net-ssh.github.io/net-sftp/classes/Net/SFTP.html#method-c-start
    def self.start(host, user = nil, options = {}, &block)
      session = new(host, user, options)

      return session unless block

      begin
        block.call(session)
      ensure
        session.close
      end
    end

    # Instance Methods

    def initialize(host = nil, user = nil, options = {})
      @options = options.is_a?(Hash) ? options.dup : {}
      @configuration = @options.delete(:configuration) || Ftpmock.configuration
      @host = host
      @username = user || @options[:user] || @options[:username]
      @password = @options[:password]
      @port = @options[:port] || PORT

      _init_cache if host
    end

    attr_writer :cache, :real
    attr_reader :configuration,
                :host,
                :port,
                :username,
                :password

    # cache / connection

    def cache
      @cache || _raise_not_connected
    end

    def _init_cache
      credentials = [host, port, username, password]
      @cache = Cache.new(configuration, credentials)
    end

    def _raise_not_connected
      raise(Ftpmock::Error, 'not connected: Net::SFTP.start requires a host')
    end

    # Lazily opens a real SFTP session. Only reached on a cache miss (i.e. while recording),
    # mirroring how the app connects: Net::SFTP::Session.new(Net::SSH.start(...)).connect!
    def real
      @real ||= begin
        @ssh = Net::SSH.start(host, username, _ssh_options)
        RealSession.new(@ssh).connect!
      end
    end

    def _ssh_options
      @options.reject { |key, _| key == :configuration }
    end

    # get methods
    # https://net-ssh.github.io/net-sftp/classes/Net/SFTP/Operations/Download.html
    def download!(remotefile, localfile = File.basename(remotefile))
      cache.get(remotefile, localfile) do
        real.download!(remotefile, localfile)
      end

      true
    end

    # put methods
    # https://net-ssh.github.io/net-sftp/classes/Net/SFTP/Operations/Upload.html
    def upload!(localfile, remotefile = File.basename(localfile))
      cache.put(localfile, remotefile) do
        real.upload!(localfile, remotefile)
      end

      true
    end

    # directory methods
    def dir
      @dir ||= Dir.new(self)
    end

    def close
      @ssh.close if @ssh.respond_to?(:close)
    ensure
      @ssh = nil
      @real = nil
    end

    include MethodMissingMixin

    # Proxies Net::SFTP::Operations::Dir. Entry names are cached through Ftpmock::Cache#list
    # (the same store the FTP proxy uses for LIST), so the listing replays offline.
    class Dir
      Entry = Struct.new(:name, :longname) do
        def directory?
          longname.to_s.start_with?('d')
        end
      end

      def initialize(session)
        @session = session
      end

      # https://net-ssh.github.io/net-sftp/classes/Net/SFTP/Operations/Dir.html#method-i-entries
      def entries(path = '.')
        names = @session.cache.list(path) do
          @session.real.dir.entries(path).map(&:name)
        end

        names.map { |name| Entry.new(name) }
      end

      def foreach(path = '.', &block)
        entries(path).each(&block)
      end

      def glob(path = '.', _pattern = '*')
        entries(path)
      end
    end
  end
end
