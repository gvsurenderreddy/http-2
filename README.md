# HTTP-2

Pure ruby, framework and transport agnostic implementation of [HTTP 2.0 protocol](http://tools.ietf.org/html/draft-ietf-httpbis-http2) (see [HPBN chapter for overview](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html)), with support for:

* [Binary framing](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#_binary_framing_layer) parsing and encoding
* [Stream multiplexing](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#HTTP2_STREAMS_MESSAGES_FRAMES) and [prioritization](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#HTTP2_PRIORITIZATION)
* Connection and stream [flow control](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#_flow_control)
* [Header compression](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#HTTP2_HEADER_COMPRESSION)
* And other HTTP 2.0 goodies...

Current implementation is based on:

* [draft-ietf-httpbis-http2-06](http://tools.ietf.org/html/draft-ietf-httpbis-http2-06)
* [draft-ietf-httpbis-header-compression-01](http://tools.ietf.org/html/draft-ietf-httpbis-header-compression)

Since the underlying specifications are still evolving, treat this implementation as a work in progress as well: the API is likely to change, there are plenty of opportunities for refactoring, etc.


## Getting started

This implementation makes no assumptions as how the data is delivered: it could be a regular Ruby TCP socket, your custom eventloop, or whatever other transport you wish to use - e.g. ZeroMQ, [avian carriers](http://www.ietf.org/rfc/rfc1149.txt), etc.

Your code is responsible for feeding data into the parser, which performs all of the necessary HTTP 2.0 decoding, state management and the rest, and vice versa, the parser will emit bytes (encoded HTTP 2.0 frames) that you can then route to the destination. Roughly, this works as follows:

```ruby
socket = YourTransport.new

conn = HTTP2::Connection.new(:client)
conn.on(:frame) {|bytes| socket << bytes }

while bytes = socket.read
 conn << bytes
end
```

Checkout provided [client](https://github.com/igrigorik/http-2/blob/master/example/client.rb) and [server]((https://github.com/igrigorik/http-2/blob/master/example/server.rb) implementations for basic examples.


### Connection lifecycle management

When the connection object is instantiated you must specify its role (`:client` or `:server`) to initialize appropriate header compression / decompression algorithms and stream management logic. From there, you can subscribe to connection level events, or invoke appropriate APIs to allocate new streams and manage the lifecycle. For example:

```ruby
# - Server ---------------
server = HTTP2::Connection.new(:server)

server.on(:stream) { |stream| ... } # process inbound stream
server.on(:frame)  { |bytes| ... }  # encoded HTTP 2.0 frames

server.ping { ... } # run liveness check, process pong response
server.goaway # send goaway frame to the client

# - Client ---------------
client = HTTP2::Connection.new(:client)
client.on(:reserved) { |stream| ... } # process push promise

stream = client.new_stream # allocate new stream
stream.headers({':method' => 'post', ...}, end_stream: false)
stream.data(payload, end_stream: true)
```

Events emitted by the connection object:

* **:reserved** - client role only, fires once for each new push promise.
* **:stream** - server role only, fires once for each new client stream.
* **:frame** - fires once for every encoded HTTP 2.0 frame that needs to be sent to the peer.


### Stream lifecycle management

A single HTTP 2.0 connection can [multiplex multiple streams](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#REQUEST_RESPONSE_MULTIPLEXING) in parallel: multiple requests and responses can be in flight simultaneously and stream data can be interleaved and prioritized. Further, the specification provides a well-defined lifecycle for each stream (see below).

The good news is, all of the stream management, and state transitions, and error checking is handled by the library. All you have to do is subscribe to appropriate events (marked with ":" prefix in diagram below) and provide your application logic to handle request and response processing.

```
                         +--------+
               Promise   |        |   Promise
                ,--------|  idle  |--------.
               /         |        |         \
              v          +--------+          v
       +----------+          |           +----------+
       |          |          | Headers   |          |
   ,---|:reserved |          |           |:reserved |---.
   |   | (local)  |          v           | (remote) |   |
   |   +----------+      +--------+      +----------+   |
   |      | :active      |        |      :active |      |
   |      |      ,-------|:active |-------.      |      |
   |      |     /        |        |        \     |      |
   |      v    v         +--------+         v    v      |
   |   +-----------+          |          +-_---------+  |
   |   |:half_close|          |          |:half_close|  |
   |   |  (remote) |          |          |  (local)  |  |
   |   +-----------+          |          +-----------+  |
   |        |                 v                |        |
   |        |            +--------+            |        |
   |        `----------->|        |<-----------'        |
   |  Reset              | :close |              Reset  |
   `-------------------->|        |<--------------------'
                         +--------+
```

For sake of example, let's take a look at a simple server implementation:

```ruby
conn = HTTP2::Connection.new(:server)

# emits new streams opened by the client
conn.on(:stream) do |stream|
  stream.on(:active) { } # fires when stream transitions to open state
  stream.on(:close)  { } # stream is closed by client and server

  stream.on(:headers) { |head| ... } # header callback
  stream.on(:data) { |chunk| ... }   # body payload callback

  # fires when client terminates its request (i.e. request finished)
  stream.on(:half_close) do

    # ... generate_response

    # send response
    stream.headers({
      ":status" => 200,
      "content-type" => "text/plain"
    })

    # split response between multiple DATA frames
    stream.data(response_chunk, end_stream: false)
    stream.data(last_chunk)
  end
end
```

Events emitted by the stream object:

<table>
  <tr>
    <td>:reserved</td>
    <td>fires at most once when server opens a push promise</td>
  </tr>
  <tr>
    <td>:active</td>
    <td>fires exactly once when the stream become active and is counted towards the open stream limit</td>
  </tr>
  <tr>
    <td>:headers</td>
    <td>fires once for each received header block (multi-frame blocks are reassembled before emitting this event)</td>
  </tr>
  <tr>
    <td>:data</td>
    <td>fires once for every DATA frame (no buffering)</td>
  </tr>
  <tr>
    <td>:half_close</td>
    <td>fires exactly once when the opposing peer closes its end of connection (e.g. client indicating that request is finished, or server indicating that response is finished)</td>
  </tr>
  <tr>
    <td>:close</td>
    <td>fires exactly once when both peers close the stream, or if the stream is reset</td>
  </tr>
  <tr>
    <td>:priority</td>
    <td>fires once for each received priority update (server only)</td>
  </tr>
</table>


### Prioritization

Each HTTP 2.0 [stream has a priority value](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#HTTP2_PRIORITIZATION) that can be sent when the new stream is initialized, and optionally reprioritized later:

```ruby
client = HTTP2::Connection.new(:client)

default_priority_stream = client.new_stream
custom_priority_stream = client.new_stream(42) # priority: 42

# sometime later: change priority value
custom_priority_stream.priority = 32000 # emits PRIORITY frame
```

On the opposite side, the server can optimize its stream processing order or resource allocation by accessing the stream priority value (`stream.priority`).


### Flow control

Multiplexing multiple streams over the same TCP connection introduces contention for shared bandwidth resources. Stream priorities can help determine the relative order of delivery, but priorities alone are insufficient to control how the resource allocation is performed between multiple streams. To address this, HTTP 2.0 provides a simple mechanism for [stream and connection flow control](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#_flow_control).

Connection and stream flow control is handled by the library: all streams are initialized with the default window size (64KB), and send/receive window updates are automatically processed - i.e. window is decremented on outgoing data transfers, and incremented on receipt of window frames. Similarly, if the window is exceeded, then data frames are automatically buffered until window is updated.

The only thing left is for your application to specify the logic as to when to emit window updates:

```ruby
conn.buffered_amount     # check amount of buffered data
conn.window              # check current window size
conn.window_update(1024) # increment connection window by 1024 bytes

stream.buffered_amount     # check amount of buffered data
stream.window              # check current window size
stream.window_update(2048) # increment stream window by 2048 bytes
```

Alternatively, flow control can be disabled by emitting an appropriate settings frame on the connection:

```ruby
conn.settings({
  settings_max_concurrent_streams: 100, # limit number of concurrent streams
  settings_flow_control_options: 1      # disable flow control
})
```

### Server push

TODO ...



### License

(MIT License) - Copyright (c) 2013 Ilya Grigorik
