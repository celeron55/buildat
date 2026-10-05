// SPDX-License-Identifier: Apache-2.0 OR MIT
// [SECURITY_RUN_1] phase 4: what a peer's bytes go through first on either
// side -- the packet stream's header, type definitions and fragments
// (interface/packet_stream.h). The input is fed in two pieces, the way a
// socket hands it over, split where its first byte says.
#include "interface/packet_stream.h"
#include <deque>
#include <stdexcept>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	if(size < 1)
		return 0;
	interface::PacketStream ps;
	ps.m_max_packet_bytes = 1 << 20;
	const size_t split = 1 + (size > 1 ? data[0] % (size - 1) : 0);
	std::deque<char> buf;
	size_t delivered = 0;
	try {
		buf.insert(buf.end(), data + 1, data + split);
		ps.input(buf, [&](const ss_ &name, const ss_ &d){
			delivered += name.size() + d.size();
		});
		buf.insert(buf.end(), data + split, data + size);
		ps.input(buf, [&](const ss_ &name, const ss_ &d){
			delivered += name.size() + d.size();
		});
	} catch(std::exception &e){
	}
	return 0;
}
