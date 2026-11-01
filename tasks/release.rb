# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'rubygems/package'
require 'tmpdir'
require_relative '../lib/breaker_machines/version'

module BreakerMachinesRelease
  ROOT = File.expand_path('..', __dir__)
  GEM = 'breaker_machines'
  REPOSITORY = "seuros/#{GEM}"
  HOST = 'https://rubygems.org'
  Artifact = Data.define(:path, :platform, :sha256)
  class Error < StandardError; end

  module_function

  def run
    yield
  rescue Error => error
    abort "#{GEM}: #{error.message}"
  end

  def version(tag = nil)
    value = (tag || BreakerMachines::VERSION).delete_prefix('v')
    unless Gem::Version.correct?(value) && Gem::Version.new(value).to_s == value
      raise Error, 'use a canonical gem version or v-prefixed release tag'
    end

    value
  end

  def verify(directory, release_version)
    checksums = {}
    File.foreach(File.join(directory, 'SHA256SUMS')) do |line|
      match = /\A([a-f0-9]{64})[ \t]+\*?(#{GEM}-[^\/\\\s]+\.gem)\n?\z/.match(line)
      raise Error, 'invalid release checksum entry' unless match
      raise Error, 'duplicate release checksum entry' if checksums.key?(match[2])

      checksums[match[2]] = match[1]
    end
    files = Dir.children(directory).grep(/\.gem\z/).sort
    raise Error, 'release gems and checksum entries differ' if files.empty? || files != checksums.keys.sort

    artifacts = files.map do |name|
      path = File.join(directory, name)
      raise Error, "checksum mismatch: #{name}" unless Digest::SHA256.file(path).hexdigest == checksums.fetch(name)

      package = Gem::Package.new(path)
      package.verify
      spec = package.spec
      unless spec.name == GEM && spec.version.to_s == release_version && spec.file_name == name
        raise Error, "unexpected release gem: #{name}"
      end
      Artifact.new(path: path, platform: spec.platform.to_s, sha256: checksums.fetch(name))
    end
    raise Error, 'release has no source-platform gem' unless artifacts.any? { it.platform == 'ruby' }

    artifacts.sort_by { [it.platform == 'ruby' ? 0 : 1, it.platform] }
  rescue Errno::ENOENT, Gem::Package::Error => error
    raise Error, error.message
  end

  def fetch(tag = nil)
    release_version = version(tag)
    destination = File.join(ROOT, 'pkg')
    FileUtils.mkdir_p(destination)
    Dir.mktmpdir("#{GEM}-release") do |directory|
      downloaded = system('gh', 'release', 'download', "#{GEM}/v#{release_version}", '--repo', REPOSITORY,
                          '--pattern', "#{GEM}-#{release_version}*.gem", '--pattern', 'SHA256SUMS',
                          '--dir', directory)
      raise Error, 'GitHub release download failed' unless downloaded

      artifacts = verify(directory, release_version)
      artifacts.map do |artifact|
        path = File.join(destination, File.basename(artifact.path))
        FileUtils.cp(artifact.path, path)
        Artifact.new(path: path, platform: artifact.platform, sha256: artifact.sha256)
      end.tap do |copied|
        FileUtils.cp(File.join(directory, 'SHA256SUMS'), destination)
        puts "Verified #{copied.size} gems for #{GEM} v#{release_version} in #{destination}"
      end
    end
  end

  def published_versions
    uri = URI("#{HOST}/api/v1/versions/#{GEM}.json")
    response = Net::HTTP.start(uri.hostname, uri.port, nil, use_ssl: true,
                               open_timeout: 5, read_timeout: 15) do |http|
      http.get(uri.request_uri)
    end
    return [] if response.code == '404'
    raise Error, "RubyGems version lookup returned HTTP #{response.code}" unless response.code == '200'

    document = JSON.parse(response.body)
    raise Error, 'invalid RubyGems version response' unless document.is_a?(Array) && document.all?(Hash)

    document
  end

  # A partially completed publication can be resumed, but never replace an
  # existing version/platform with different bytes.
  def pending(artifacts, versions, release_version)
    artifacts.reject do |artifact|
      existing = versions.find { it['number'] == release_version && it['platform'] == artifact.platform }
      next false unless existing
      raise Error, "RubyGems already has different bytes for #{artifact.platform}" unless existing['sha'] == artifact.sha256

      puts "Already published: #{File.basename(artifact.path)}"
      true
    end
  end

  def push_all(tag = nil)
    release_version = version(tag)
    artifacts = pending(fetch(tag), published_versions, release_version)
    require 'bundler'
    otp = ENV.fetch('GEM_OTP', nil)
    artifacts.each do |artifact|
      command = [Gem.ruby, '-S', 'gem', 'push', artifact.path, '--host', HOST]
      command.push('--otp', otp) unless otp.nil? || otp.empty?
      success = Bundler.with_unbundled_env { system(*command) }
      raise Error, "not pushed: #{File.basename(artifact.path)}; rerun gems:push_all to resume" unless success
    end
    puts "All release gems published for #{GEM} v#{release_version}"
  end
end
