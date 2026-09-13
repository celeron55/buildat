// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/compress.h"
#include "core/log.h"
#define MODULE "compress"

#include "zlib.h"
#include "zstd.h"

namespace interface {

ss_ zerr(int ret)
{
	switch(ret){
	case Z_ERRNO:
		if(ferror(stdin))
			return "error reading stdin";
		if(ferror(stdout))
			return "error writing stdout";
		return "errno";
	case Z_STREAM_ERROR:
		return "invalid compression level";
	case Z_DATA_ERROR:
		return "invalid or incomplete deflate data";
	case Z_MEM_ERROR:
		return "out of memory";
	case Z_VERSION_ERROR:
		return "zlib version mismatch!";
	default:
		return ss_()+"error value = "+itos(ret);
	}
}

// Negative window bits is zlib's way of saying "no header and no checksum",
// which is what a raw deflate stream is
static void compress_deflate(const ss_ &data_in, std::ostream &os, int level,
		int window_bits)
{
	z_stream z;
	const size_t bufsize = 16384;
	char output_buffer[bufsize];
	int status = 0;
	int ret;

	z.zalloc = Z_NULL;
	z.zfree = Z_NULL;
	z.opaque = Z_NULL;

	ret = deflateInit2(&z, level, Z_DEFLATED, window_bits, 8,
			Z_DEFAULT_STRATEGY);
	if(ret != Z_OK)
		throw Exception("compress_zlib: deflateInit failed");

	// Point zlib to our input buffer
	z.next_in = (Bytef*)data_in.c_str();
	z.avail_in = data_in.size();
	// And get all output
	for(;;)
	{
		z.next_out = (Bytef*)output_buffer;
		z.avail_out = bufsize;

		status = deflate(&z, Z_FINISH);
		if(status == Z_NEED_DICT || status == Z_DATA_ERROR
				|| status == Z_MEM_ERROR)
		{
			zerr(status);
			throw Exception("compress_zlib: deflate failed");
		}
		int count = bufsize - z.avail_out;
		if(count)
			os.write(output_buffer, count);
		// This determines zlib has given all output
		if(status == Z_STREAM_END)
			break;
	}

	deflateEnd(&z);
}

void compress_zlib(const ss_ &data_in, std::ostream &os, int level)
{
	compress_deflate(data_in, os, level, MAX_WBITS);
}

void compress_deflate_raw(const ss_ &data_in, std::ostream &os, int level)
{
	compress_deflate(data_in, os, level, -MAX_WBITS);
}

static void decompress_deflate(std::istream &is, std::ostream &os,
		int window_bits)
{
	z_stream z;
	const size_t bufsize = 16384;
	char input_buffer[bufsize];
	char output_buffer[bufsize];
	int status = 0;
	int ret;
	int bytes_read = 0;
	int input_buffer_len = 0;

	z.zalloc = Z_NULL;
	z.zfree = Z_NULL;
	z.opaque = Z_NULL;

	ret = inflateInit2(&z, window_bits);
	if(ret != Z_OK)
		throw Exception("dcompress_zlib: inflateInit failed");

	z.avail_in = 0;

	//dstream<<"initial fail="<<is.fail()<<" bad="<<is.bad()<<std::endl;

	for(;;)
	{
		z.next_out = (Bytef*)output_buffer;
		z.avail_out = bufsize;

		if(z.avail_in == 0)
		{
			z.next_in = (Bytef*)input_buffer;
			input_buffer_len = is.readsome(input_buffer, bufsize);
			z.avail_in = input_buffer_len;
			//dstream<<"read fail="<<is.fail()<<" bad="<<is.bad()<<std::endl;
		}
		if(z.avail_in == 0)
		{
			//dstream<<"z.avail_in == 0"<<std::endl;
			break;
		}

		//dstream<<"1 z.avail_in="<<z.avail_in<<std::endl;
		status = inflate(&z, Z_NO_FLUSH);
		//dstream<<"2 z.avail_in="<<z.avail_in<<std::endl;
		bytes_read += is.gcount() - z.avail_in;
		//dstream<<"bytes_read="<<bytes_read<<std::endl;

		if(status == Z_NEED_DICT || status == Z_DATA_ERROR
				|| status == Z_MEM_ERROR)
		{
			zerr(status);
			throw Exception("decompress_zlib: inflate failed");
		}
		int count = bufsize - z.avail_out;
		//dstream<<"count="<<count<<std::endl;
		if(count)
			os.write(output_buffer, count);
		if(status == Z_STREAM_END)
		{
			//dstream<<"Z_STREAM_END"<<std::endl;

			//dstream<<"z.avail_in="<<z.avail_in<<std::endl;
			//dstream<<"fail="<<is.fail()<<" bad="<<is.bad()<<std::endl;
			// Unget all the data that inflate didn't take
			for(size_t i = 0; i < z.avail_in; i++)
			{
				is.unget();
				if(is.fail() || is.bad())
				{
					log_w(MODULE, "unget #%zu failed", i);
					log_w(MODULE, "fail=%i bad=%i", is.fail(), is.bad());
					throw Exception("decompress_zlib: unget failed");
				}
			}

			break;
		}
	}

	inflateEnd(&z);
}

void decompress_zlib(std::istream &is, std::ostream &os)
{
	decompress_deflate(is, os, MAX_WBITS);
}

void decompress_deflate_raw(std::istream &is, std::ostream &os)
{
	decompress_deflate(is, os, -MAX_WBITS);
}


void compress_zstd(const ss_ &data_in, std::ostream &os, int level)
{
	size_t bound = ZSTD_compressBound(data_in.size());
	ss_ buffer(bound, '\0');
	size_t size = ZSTD_compress(&buffer[0], bound,
			data_in.c_str(), data_in.size(), level);
	if(ZSTD_isError(size))
		throw Exception(ss_("compress_zstd: ") + ZSTD_getErrorName(size));
	os.write(buffer.c_str(), size);
}

size_t decompress_zstd(const ss_ &data_in, std::ostream &os)
{
	ZSTD_DStream *stream = ZSTD_createDStream();
	if(stream == nullptr)
		throw Exception("decompress_zstd: ZSTD_createDStream failed");
	const size_t bufsize = ZSTD_DStreamOutSize();
	ss_ buffer(bufsize, '\0');
	ZSTD_inBuffer input = {data_in.c_str(), data_in.size(), 0};
	for(;;){
		ZSTD_outBuffer output = {&buffer[0], bufsize, 0};
		size_t ret = ZSTD_decompressStream(stream, &output, &input);
		if(ZSTD_isError(ret)){
			ss_ error = ZSTD_getErrorName(ret);
			ZSTD_freeDStream(stream);
			throw Exception("decompress_zstd: " + error);
		}
		if(output.pos)
			os.write(buffer.c_str(), output.pos);
		if(ret == 0)
			break; // The frame ended
		if(input.pos == input.size && output.pos == 0){
			ZSTD_freeDStream(stream);
			throw Exception("decompress_zstd: the frame is not complete");
		}
	}
	ZSTD_freeDStream(stream);
	return input.pos;
}

}
// vim: set noet ts=4 sw=4:
