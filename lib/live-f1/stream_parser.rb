require 'timeout'
require 'socket'
require 'open-uri'

module LiveF1

	# A StreamParser is the Ruby representation of the F1 live timing stream.
	# 
	# The StreamParser can take its input from different sources. The most common source
	# will be the live-timing server, but the aim is that a local file can also be
	# used to replay a race, or for testing purposes.
	class StreamParser

		attr_accessor :source

		INITIAL_DECRYPTION_SALT = 0x55555555

		# Creates a representation of the F1 Live Timing stream.
		# 
		# You can optionally specify the source used by this StreamParser
		# 
		# nil::              The default connection to the live-timing server will be used
		# a File or String:: The specified file (or filename) will be used
		# 
		# or pass any initialised StreamParser::Source to use that.
		# 
		# Yields the selected Source so that it can be examined/altered if
		# necessary.
		def initialize source = nil # :yields: source
			self.source = case source
			when Source
				source
			when nil
				Source::Live.new
			when File, String
				Source::Log.new(source)
			end
			yield self.source if block_given?
		end

		# Parses the stream, including packets retrieved from the most recent
		# keyframe.
		# 
		# Yields the following parameters to the block:
		# 
		# is_live:: false for packets generated from the initial keyframe, true for packets generated from the stream
		# packet:: the generated packet
		def run &block # :yields: is_live, packet
			parse source.keyframe do |packet|
				yield false, packet if block_given?
			end
			parse source do |packet|
				yield true, packet if block_given?
			end
		end

		# Decrypts the specified bytes using decryption information specified
		# previously from the stream.
		# 
		# Certain packets in the stream aren't transmitted in plaintext, instead
		# they are encrypted using a shift/xor cipher. This method decrypts the
		# given bytes and shifts the salt accordingly.
		# 
		# Used internally by the stream parsing methods.
		def decrypt bytes # :nodoc:
			bytes = (bytes||"").dup
			bytes.length.times do |i|
				@decryption_salt = (@decryption_salt >> 1) ^ (!(@decryption_salt & 0x01).zero? ? @decryption_key : 0)
				bytes[i] ^= (@decryption_salt & 0xff)
			end
			bytes
		end

		# Consumes the specified number of bytes from the stream and returns them.
		# 
		# Used internally by the stream parsing methods.
		def read_bytes number # :nodoc:
			source.read_bytes number
		end

		# Consumes the next packet from the stream and returns it, ignoring any unexpected packets
		# 
		# Used internally by the stream parsing methods.
		def read_packet # :nodoc:
			Packet.from_stream(self)
		rescue Packet::InvalidPacket => e
			retry
		end

		private
		def parse source
			oldsource = self.source
			self.source = source
			while(packet = read_packet)
				case packet
				when Packet::Sys::EventStart
					@decryption_key = source.decryption_key(packet.session_number).to_i(16)
					@decryption_salt = INITIAL_DECRYPTION_SALT
				when Packet::Sys::KeyFrame
					@decryption_salt = INITIAL_DECRYPTION_SALT
				end

				yield packet if block_given?

				# case packet
				# when Packet::Sys::KeyFrame
				# 	begin
				# 		parse source.keyframe(packet.number) do |p|
				# 			yield p if block_given?
				# 		end
				# 	rescue NotImplementedError => e
				# 	end
				# end
			end
		rescue EOFError => e
		ensure
			self.source = oldsource
		end

		# A Source acts as a proxy for all the information that can be loaded from
		# the live timing service.
		class Source
			# Returns the decryption key for a given session.
			def decryption_key(session)
				raise NotImplementedError
			end

			# Returns a new Source representing the specified keyframe.
			def keyframe(number = nil)
				raise NotImplementedError
			end

			# Reads a certain number of bytes from the source.
			def read_bytes(number)
				raise NotImplementedError
			end

			# A Live source is designed to connect to a server acting like the F1
			# live timing server.
			# 
			# A valid live timing username and password is required to get the
			# session keys from the live timing service.
			class Live < Source
				HOST = "live-timing.formula1.com"
				PORT = 4321

				attr_accessor :username, :password, :host, :port

				# Initialises a live source with a specified username and password,
				# and optional host and port.
				def initialize(opts = nil)
					opts = {} unless opts.respond_to?(:[])
					@username = opts[:username]
					@password = opts[:password]
					@host     = opts[:host] || HOST
					@port     = opts[:port] || PORT
				end

				# Returns the decryption key for a given session.
				def decryption_key(session)
					open("http://live-timing.formula1.com/reg/getkey/#{session}.asp?auth=#{auth}").read
				end

				# Returns a new Source representing the specified keyframe.
				def keyframe(number = nil)
					Keyframe.new "http://#{@host}/keyframe#{ "_%05d" % number if number}.bin", self
				end

				# Reads a certain number of bytes from the source.
				def read_bytes(number)
					buffer = ""
					number.times do
						byte = read_byte or return nil # TODO: Check whether `return nil` is right
						buffer << byte
					end
					buffer
				end

				private
				def read_byte
					begin
						Timeout.timeout(0.5) do
							b = socket.read 1
						end
					rescue Timeout::Error => e
						socket.write("\n")
						socket.flush
						retry
					end
				end

				def socket
					@socket ||= TCPSocket.open @host, @port
				rescue SocketError
					# TODO: raise a specific error
					raise "Unable to open connection to #{@host} with given parameters"
				end

				def auth
					response = Net::HTTP.post_form URI.parse("http://#{@host}/reg/login.asp"), {"email" => @username, "password" => @password}
					CGI::Cookie.parse(response["Set-Cookie"])["USER"].first
				rescue # TODO: rescue a specific exception
					# Implicit nil
				end
			end

			class Keyframe < Source # :nodoc:
				def initialize source, parent
					@io = open(source)
					@parent = parent
				end

				def read_bytes number
					raise EOFError if @io.eof?
					@io.read(number)
				end

				def decryption_key(session)
					@parent.decryption_key(session)
				end
			end

			# A Log source is intented to be used to play back a previously session
			# where the live stream has been saved.
			class Log < Source
				class << self
					# Find the last entry in the last folder in data
					def latest_infile
						Dir[Dir["data/*"].last+"/*.*"].last
					end
				end

				def initialize infile
					infile = infile.empty? ? self.class.latest_infile : infile
					@io = open(infile)
				end

				# Returns the decryption key for a given session
				def decryption_key(session)
					open(File.join(base, "session", "#{session}.key")).read
				end

				# Returns a new Source representing the specified keyframe
				def keyframe number = nil
					Keyframe.new(File.join(base, "keyframe", "keyframe#{ "_%05d" % number if number}.bin" ), self)
				end

				# Reads a certain number of bytes from the source
				def read_bytes(number)
					raise EOFError if @io.eof?
					@io.read(number)
				end

				private
				def base
					File.dirname(@io.path)
				end
			end
		end

	end
end