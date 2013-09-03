module Net
  module HTTP2

    DEFAULT_FLOW_WINDOW = 65535
    DEFAULT_PRIORITY    = 2**30
    CONNECTION_HEADER   = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

    class Connection
      include FrameSplitter
      include Emitter

      attr_reader :type, :window, :state, :error
      attr_reader :stream_limit, :active_stream_count

      def initialize(type = :client)
        @type = type

        @stream_id = (@type == :client) ? 1 : 2
        @stream_limit = Float::INFINITY
        @active_stream_count = 0
        @streams = {}

        @framer = Framer.new
        @window = DEFAULT_FLOW_WINDOW
        @window_limit = DEFAULT_FLOW_WINDOW

        @send_buffer = []
        @state = :new
        @error = nil
      end

      def new_stream
        raise StreamLimitExceeded.new if @active_stream_count == @stream_limit

        @stream_id += 2
        activate_stream(@stream_id)
      end

      def receive(data)
        data = StringIO.new(data)

        while frame = @framer.parse(data) do
          # SETTINGS frames always apply to a connection, never a single stream.
          # The stream identifier for a settings frame MUST be zero.  If an
          # endpoint receives a SETTINGS frame whose stream identifier field is
          # anything other than 0x0, the endpoint MUST respond with a connection
          # error (Section 5.4.1) of type PROTOCOL_ERROR.
          if (frame[:stream] == 0 || frame[:type] == :settings)
            connection_management(frame)
          else
            case frame[:type]
            when :push_promise
              # HEADERS, PUSH_PROMISE and CONTINUATION frames carry data that
              # can modify the compression context maintained by a receiver.
              # An endpoint receiving HEADERS, PUSH_PROMISE or CONTINUATION
              # frames MUST reassemble header blocks and perform decompression
              # even if the frames are to be discarded, which is likely to
              # occur after a stream is reset.

              # TODO ...


              # PUSH_PROMISE frames MUST be associated with an existing, peer-
              # initiated stream... A receiver MUST treat the receipt of a
              # PUSH_PROMISE on a stream that is neither "open" nor
              # "half-closed (local)" as a connection error (Section 5.4.1) of
              # type PROTOCOL_ERROR. Similarly, a receiver MUST treat the
              # receipt of a PUSH_PROMISE that promises an illegal stream
              # identifier (Section 5.1.1) (that is, an identifier for a stream
              # that is not currently in the "idle" state) as a connection error
              # (Section 5.4.1) of type PROTOCOL_ERROR, unless the receiver
              # recently sent a RST_STREAM frame to cancel the associated stream.
              parent = @streams[frame[:stream]]
              pid = frame[:promise_stream]

              connection_error if parent.nil?
              connection_error if @streams.include? pid

              if !(parent.state == :open || parent.state == :half_closed_local)
                # An endpoint might receive a PUSH_PROMISE frame after it sends
                # RST_STREAM.  PUSH_PROMISE causes a stream to become "reserved".
                # The RST_STREAM does not cancel any promised stream.  Therefore, if
                # promised streams are not desired, a RST_STREAM can be used to
                # close any of those streams.
                if parent.closed == :local_rst
                  # We can either (a) 'resurrect' the parent, or (b) RST_STREAM
                  # ... sticking with (b), might need to revisit later.
                  process({type: :rst_stream, stream: pid, error: :refused_stream})
                else
                  connection_error
                end
              end

              stream = activate_stream(pid)
              stream.process(frame)

              emit(:promise, stream)
            else
              @streams[frame[:stream]].process frame
            end
          end
        end
      end
      alias :<< :receive

      private

      def process(frame)
        if frame[:type] != :data
          # send immediately
        else
          send_data(frame)
        end
      end

      def connection_management(frame)
        case @state
        # SETTINGS frames MUST be sent at the start of a connection.
        when :new
          connection_settings(frame)
          @state = :connected

        when :connected
          case frame[:type]
          when :settings
            connection_settings(frame)
          when :window_update
            flow_control_allowed?
            @window += frame[:increment]
            send_data
          else
            connection_error
          end
        else
          connection_error
        end
      end

      def connection_settings(frame)
        if (frame[:type] != :settings || frame[:stream] != 0)
          connection_error
        end

        frame[:payload].each do |key,v|
          case key
          when :settings_max_concurrent_streams
            @stream_limit = v

          # A change to SETTINGS_INITIAL_WINDOW_SIZE could cause the available
          # space in a flow control window to become negative. A sender MUST
          # track the negative flow control window, and MUST NOT send new flow
          # controlled frames until it receives WINDOW_UPDATE frames that cause
          # the flow control window to become positive.
          when :settings_initial_window_size
            flow_control_allowed?
            @window = @window - @window_limit + v
            @streams.each do |id, stream|
              stream.emit(:window, stream.window - @window_limit + v)
            end

            @window_limit = v

          # Flow control can be disabled the entire connection using the
          # SETTINGS_FLOW_CONTROL_OPTIONS setting. This setting ends all forms
          # of flow control. An implementation that does not wish to perform
          # flow control can use this in the initial SETTINGS exchange.
          when :settings_flow_control_options
            flow_control_allowed?

            if v == 1
              @window = @window_limit = Float::INFINITY
            end
          end
        end
      end

      def flow_control_allowed?
        if @window_limit == Float::INFINITY
          connection_error(:flow_control_error)
        end
      end

      def activate_stream(id)
        stream = Stream.new(id, DEFAULT_PRIORITY, @window)

        # Streams that are in the "open" state, or either of the "half closed"
        # states count toward the maximum number of streams that an endpoint is
        # permitted to open.
        stream.once(:active) { @active_stream_count += 1 }
        stream.once(:close)  { @active_stream_count -= 1 }
        stream.on(:frame)    { |frame| process(frame) }

        @streams[id] = stream
      end

      def connection_error(error = :protocol_error)
        if @state != :closed
          process({type: :rst_stream, stream: 0, error: error})
        end

        @state, @error = :closed, error
        klass = error.to_s.split('_').map(&:capitalize).join
        raise Kernel.const_get(klass).new
      end

    end
  end
end