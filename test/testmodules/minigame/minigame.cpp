#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "client_file/api.h"
#include "network/api.h"
#include "core/log.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/vector.hpp>
#include <cstdlib>

using interface::Event;

namespace minigame {

struct Playfield
{
	size_t w = 0;
	size_t h = 0;
	sv_<int> tiles;
	Playfield(size_t w, size_t h): w(w), h(h){
		tiles.resize(w * h);
	}
	int get(int x, int y){
		size_t i = y * w + x;
		if(i > tiles.size())
			return 0;
		return tiles[i];
	}
	void set(int x, int y, int v){
		size_t i = y * w + x;
		if(i > tiles.size())
			return;
		if(!inside_field(x,y))
			return;
		tiles[i] = v;
	}

	bool inside_field(int x, int y){
		if (x >= w || x < 0)
			return false;
		if (y >= h || y < 0)
			return false;
		return true;
	}

	template<class Archive>
	void serialize(Archive &archive){
		archive((int32_t)w, (int32_t)h);
		archive(tiles);
	}
};

struct Player
{
	int peer = 0;
	int x = 0;
	int y = 0;

	Player(int peer = 0, int x = 0, int y = 0): peer(peer), x(x), y(y){}

	template<class Archive>
	void serialize(Archive &archive){
		archive((int32_t)peer, (int32_t)x, (int32_t)y);
	}
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	Playfield m_playfield;
	sm_<int, Player> m_players;

	Module(interface::Server *server):
		interface::Module("minigame"),
		m_server(server),
		m_playfield(10, 10)
	{
		log_v(MODULE, "minigame construct");
	}

	~Module()
	{
		log_v(MODULE, "minigame destruct");
	}

	void init()
	{
		log_v(MODULE, "minigame init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:new_client"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("network:packet_received/minigame:move"));
		m_server->sub_event(this,
				Event::t("network:packet_received/minigame:clear_field"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:new_client", on_new_client, network::NewClient)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/minigame:move", on_packet_move,
				network::Packet)
		EVENT_TYPEN("network:packet_received/minigame:clear_field",
				on_packet_clear_field, network::Packet)
	}

	void on_start()
	{
	}

	void send_update(int peer)
	{
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((int32_t)peer);
			ar(m_players);
			ar(m_playfield);
		}
		network::access(m_server, [&](network::Interface * inetwork){
			inetwork->send(peer, "minigame:update", os.str());
		});
	}

	void on_new_client(const network::NewClient &new_client)
	{
		log_i(MODULE, "minigame::on_new_client: id=%zu", new_client.info.id);

		int peer = new_client.info.id;

		m_players[peer] = Player(peer, rand() % 10, rand() % 10);

		for(auto &pair : m_players)
			send_update(pair.second.peer);
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		log_i(MODULE, "minigame::on_client_disconnected: id=%zu", old_client.info.id);

		int peer = old_client.info.id;

		m_players.erase(peer);

		for(auto &pair : m_players)
			send_update(pair.second.peer);
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		log_v(MODULE, "on_files_transmitted(): recipient=%zu", event.recipient);

		network::access(m_server, [&](network::Interface * inetwork){
			inetwork->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"minigame/init.lua\")");
		});

		send_update(event.recipient);
	}

	void on_packet_move(const network::Packet &packet)
	{
		log_i(MODULE, "minigame::on_packet_move: name=%zu, size=%zu",
				cs(packet.name), packet.data.size());
		auto it = m_players.find(packet.sender);
		if(it == m_players.end()){
			log_w(MODULE, "Player not found: %i", packet.sender);
			return;
		}
		Player &player = it->second;
		if(packet.data == "up")
			player.x -= 1;
		if(packet.data == "down")
			player.x += 1;
		if(packet.data == "left")
			player.y -= 1;
		if(packet.data == "right")
			player.y += 1;
		if(packet.data == "place"){
			m_playfield.set(player.x, player.y,
					m_playfield.get(player.x, player.y) + 1);
		}

		for(auto &pair : m_players)
			send_update(pair.second.peer);
	}

	void on_packet_clear_field(const network::Packet &packet)
	{
		log_i(MODULE, "minigame::on_packet_clear_field: name=%zu, size=%zu",
				cs(packet.name), packet.data.size());

		for(size_t y = 0; y < m_playfield.h; y++)
			for(size_t x = 0; x < m_playfield.w; x++)
				m_playfield.set(x, y, 0);

		for(auto &pair : m_players)
			send_update(pair.second.peer);
	}
};

extern "C" {
	EXPORT void* createModule_minigame(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
