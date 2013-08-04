module Http2
  module Parser

    class CompressionContext
    end

    class Compressor

      # Integer representation:
      # http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-01#section-4.2.1
      #
      # 1. If I < 2^N - 1, encode I on N bits
      # 2. Else, encode 2^N - 1 on N bits and do the following steps:
      #  1. Set I to (I - (2^N - 1)) and Q to 1
      #  2. While Q > 0
      #    1. Compute Q and R, quotient and remainder of I divided by 2^7
      #    2. If Q is strictly greater than 0, write one 1 bit; otherwise, write one 0 bit
      #    3. Encode R on the next 7 bits
      #    4. I = Q
      #
      def integer(i, n)
        limit = 2**n - 1
        return [i].pack('C') if (i < limit)

        bytes = []
        bytes.push limit if !n.zero?

        i -= limit
        q = 1

        while (q > 0) do
          q = i/128
          r = i%128

          r += 128 if (q > 0)
          bytes.push(r)

          i = q
        end

        return bytes.pack('C*')
      end

    end

    class Decompressor

      def integer(buf, n, cursor = 0)
        limit = 2**n - 1

        i = buf.unpack('C').first & limit
        cursor = 1 if !n.zero?

        if i == limit
          m = 0
          begin
            i += (buf[cursor].unpack('C').first & 127) << m
            m += 7
            cursor += 1
          end while !(buf[cursor - 1].unpack('C').first & 128).zero?
        end

        return i
      end

    end

  end
end