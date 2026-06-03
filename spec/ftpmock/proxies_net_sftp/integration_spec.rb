require 'spec_helper'

RSpec.describe Ftpmock::NetSftpProxy do
  describe 'Integration (replay from recorded cache)' do
    let(:host) { 'sftp.example.com' }
    let(:user) { 'user1' }
    let(:options) { { password: 'changeme123', port: 22 } }

    around do |example|
      Ftpmock.on! { example.run }
    end

    describe 'download!' do
      let(:remotefile) { 'catalog.txt' }
      let(:localfile)  { 'tmp/sftp-catalog.txt' }

      after { FileUtils.rm_f(localfile) }

      example 'reproduces the cached file (no real network call)' do
        Net::SFTP.start(host, user, options) do |sftp|
          sftp.download!(remotefile, localfile)
        end

        expect(File).to exist(localfile)
        expect(File.read(localfile)).to eq("SKU1~A\nSKU2~B\n")
      end

      example 'stores the cached file under the expected path' do
        expect(File).to exist('spec/records/sftp-example-com_22_user1_changeme123/get/catalog_txt')
      end
    end

    describe 'dir.entries' do
      example 'replays the cached directory listing as objects responding to #name' do
        names = nil
        Net::SFTP.start(host, user, options) do |sftp|
          names = sftp.dir.entries('/').map(&:name)
        end

        expect(names).to eq(%w[catalog.txt readme.md])
      end
    end
  end

  describe 'delegation (recording path)' do
    let(:proxy) { Ftpmock::NetSftpProxy.new('sftp.example.com', 'user1', password: 'p', port: 22) }

    example 'download! delegates to cache#get and the real session' do
      proxy.real = double('Real')
      proxy.cache = double('Cache')

      expect(proxy.cache).to receive(:get).with('remote.txt', 'local.txt').and_yield
      expect(proxy.real).to receive(:download!).with('remote.txt', 'local.txt')

      expect(proxy.download!('remote.txt', 'local.txt')).to eq(true)
    end

    example 'upload! delegates to cache#put and the real session' do
      proxy.real = double('Real')
      proxy.cache = double('Cache')

      expect(proxy.cache).to receive(:put).with('local.txt', 'remote.txt').and_yield
      expect(proxy.real).to receive(:upload!).with('local.txt', 'remote.txt')

      expect(proxy.upload!('local.txt', 'remote.txt')).to eq(true)
    end
  end

  describe '.start' do
    example 'yields a session and closes it afterwards' do
      session = instance_double(Ftpmock::NetSftpProxy)
      allow(Ftpmock::NetSftpProxy).to receive(:new).and_return(session)
      expect(session).to receive(:close)

      yielded = nil
      Ftpmock::NetSftpProxy.start('h', 'u', password: 'p') { |s| yielded = s }

      expect(yielded).to eq(session)
    end
  end
end
