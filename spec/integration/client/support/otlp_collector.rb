# frozen_string_literal: true

require "socket"
require "stringio"
require "zlib"
require "opentelemetry/exporter/otlp"
require "opentelemetry/exporter/otlp_metrics"

# Receives the official exporters' actual HTTP/protobuf requests, including gzip.
class OtlpCollector
  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @endpoint = "http://127.0.0.1:#{@server.addr[1]}/"
    @lock = Mutex.new
    @requests = []
    @errors = []
    @thread = Thread.new do
      loop do
        receive(@server.accept)
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end

  attr_reader :endpoint

  def requests = @lock.synchronize { @requests.dup }
  def errors = @lock.synchronize { @errors.dup }

  def spans
    requests.select { |request| request[:path] == "/v1/traces" }.flat_map do |request|
      request[:message].resource_spans.flat_map do |resource|
        attributes = self.class.attributes(resource.resource.attributes)
        resource.scope_spans.flat_map { |scope| scope.spans.map { |span| { resource: attributes, span: } } }
      end
    end
  end

  def metrics
    requests.select { |request| request[:path] == "/v1/metrics" }.flat_map do |request|
      request[:message].resource_metrics.flat_map do |resource|
        attributes = self.class.attributes(resource.resource.attributes)
        resource.scope_metrics.flat_map { |scope| scope.metrics.map { |metric| { resource: attributes, metric: } } }
      end
    end
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "OTLP collector failed: #{errors.inspect}" unless errors.empty?
      raise "OTLP collector timed out after #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  def close
    @server.close
    raise "OTLP collector did not stop" unless @thread.join(2)

    @thread.value
  end

  def self.attributes(values)
    values.to_h { |attribute| [attribute.key, attribute.value.public_send(attribute.value.value)] }
  end

  private

  def receive(socket)
    request_line = socket.gets("\r\n")
    return unless request_line

    headers = {}
    while (line = socket.gets("\r\n")) && line != "\r\n"
      key, value = line.strip.split(":", 2)
      headers[key.downcase] = value.strip
    end
    body = socket.read(Integer(headers.fetch("content-length")))
    body = Zlib::GzipReader.new(StringIO.new(body)).read if headers["content-encoding"] == "gzip"
    path = request_line.split.fetch(1)
    type = case path
           when "/v1/traces" then Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest
           when "/v1/metrics" then Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceRequest
           else raise "unexpected OTLP path #{path}"
           end
    message = type.decode(body)
    @lock.synchronize { @requests << { path:, headers:, message: } }
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
  rescue StandardError => e
    @lock.synchronize { @errors << e }
    begin
      socket.write("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    rescue IOError, SystemCallError
      nil
    end
  ensure
    socket.close
  end
end
