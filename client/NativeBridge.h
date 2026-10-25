#pragma once

#include <string>
#include <vector>

namespace wo_native
{
	enum class InboundOpcode
	{
		None = 0,
		Move = 1,
		Update1 = 2,
		Update2 = 3,
		Update3 = 4,
		Update4 = 5,
		UsernameTaken = 6,
		Kicked = 7,
		Banned = 8,
		NotWhitelisted = 9,
		Coop = 10,
		// fields: what doesn't match ("mod" or "game"), the host's version
		VersionMismatch = 11,
		// nothing from the server for a while / packets again after that
		ConnectionLost = 12,
		ConnectionRestored = 13,
		// the co-op kill switch hotkey (Ctrl+F9) was pressed
		ToggleCoop = 14,
		// ServerIP "auto" and no host answered on the LAN
		NoHostFound = 15
	};

	struct InboundMessage
	{
		InboundOpcode opcode = InboundOpcode::None;
		int playerId = 0;
		std::string sender;
		std::vector<std::string> fields;
	};

	void InitLog(const std::string &path);
	void ShutdownLog();
	void DebugLog(const std::string &text);

	bool RegisterNatives();

	bool IsConnected();
	void SetConnected(bool connected);
	void SetLocalId(int id);
	void SetUsername(const std::string &name);
	// LAN co-op: who hosts (announced by a server started with --lan), this game's role ("host", "member" or ""
	// outside LAN co-op) and the save the join launcher handed over (the member loads it at the main menu)
	void SetHostName(const std::string &name);
	void SetLanInfo(const std::string &role, const std::string &autoLoadSave);

	bool PopOutbound(std::string &payload);
	void PushInbound(InboundMessage &&message);
	void PushControl(InboundOpcode opcode);
	void PushControl(InboundOpcode opcode, std::vector<std::string> &&fields);
} // namespace wo_native
