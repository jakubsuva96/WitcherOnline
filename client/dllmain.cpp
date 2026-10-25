#include "NativeBridge.h"
#include "crash.h"
#include "pch.h"
#include "profile.h"

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <filesystem>
#include <iostream>
#include <mutex>
#include <regex>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include "pugixml\pugixml.hpp"

#define ASIO_STANDALONE
#include <asio.hpp>

namespace fs = std::filesystem;

static std::string username = "Player";
static std::string ip = "46.62.255.79";
static std::string port = "40000";

// The receiver thread renames the player when the server says the name is taken, while the sender thread builds
// packets with it.
static std::mutex usernameMu;

static std::string GetLocalUsername()
{
	std::lock_guard<std::mutex> lock(usernameMu);
	return username;
}

static void SetLocalUsername(const std::string &name)
{
	{
		std::lock_guard<std::mutex> lock(usernameMu);
		username = name;
	}
	wo_native::SetUsername(name);
}

// W3Coop version handshake: HELLO until the server answers WELCOME, or an ERROR saying what doesn't match.
// Keep in step with WitcherServer.PROTOCOL_VERSION / MOD_VERSION.
static const char *const kProtocolVersion = "1";
static const char *const kModVersion = "0.3.0-dev";
static constexpr int kHelloAttempts = 15;
static constexpr ULONGLONG kHelloIntervalMs = 1000;
static std::string g_gameVersion = "unknown";
static std::atomic<bool> g_welcomed{false};
static std::atomic<int> g_helloAttemptsSent{0};
static std::atomic<ULONGLONG> g_lastHelloTick{0};
static int g_crashReportPort = 0;

// "Player", "Player2", ...: a name the server has already given to someone else gets a number instead of ending the
// session (two PCs that both kept the default name used to lock the second one out)
static constexpr int kMaxRenames = 5;
static constexpr ULONGLONG kRenameSettleMs = 1500;
static std::string g_baseUsername = "Player";
static int g_renames = 0;
static ULONGLONG g_lastRenameTick = 0;
static HANDLE g_initThread = NULL;
static std::atomic<int> g_localPlayerId{0};
static std::atomic<bool> g_shutdown{false};
static std::atomic<bool> g_run{false};

static asio::io_context io;
static asio::ip::udp::resolver resolver(io);
static asio::ip::udp::socket theSocket(io);
static asio::ip::udp::endpoint serverEndpoint;

static bool PinClientModule()
{
	HMODULE pinnedModule = nullptr;
	return GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN, reinterpret_cast<LPCWSTR>(&PinClientModule), &pinnedModule) != FALSE;
}

struct ParsedHalves
{
	std::vector<std::string> first;
	std::vector<std::string> second;
};

struct RemotePlayerChunks
{
	std::string username;

	std::vector<std::string> update1A;
	std::vector<std::string> update1B;
	std::vector<std::string> update2A;
	std::vector<std::string> update2B;

	std::vector<std::string> lastUpdate1;
	std::vector<std::string> lastUpdate2;
	std::vector<std::string> lastUpdate3;
	std::vector<std::string> lastUpdate4;

	int update1ASequence = 0;
	int update1BSequence = 0;

	int update1AMovementSequence = 0;
	int update1BMovementSequence = 0;

	int update2ASequence = 0;
	int update2BSequence = 0;

	int lastPushed1Sequence = 0;
	int lastPushed2Sequence = 0;

	// last COOP fields per channel, so the server's rebroadcasts of an unchanged state reach the script once
	std::unordered_map<std::string, std::vector<std::string>> lastCoop;
};

static std::mutex remoteMu;
static std::unordered_map<int, RemotePlayerChunks> remotePlayers;

static fs::path getExecutablePath()
{
	char buffer[MAX_PATH]{};
	GetModuleFileNameA(NULL, buffer, MAX_PATH);
	return fs::path(buffer).parent_path().parent_path();
}

static ParsedHalves ParseValuesSplitHalf(const std::string &input)
{
	static const std::string kStartMarker = "_s";
	static const std::string kEndMarker = "_e";
	static const std::string kHalfMarker = "half";

	std::istringstream iss(input);
	std::string word;
	ParsedHalves out;
	std::vector<std::string> *current = &out.first;

	if (!(iss >> word))
		return out;

	bool inBlock = false;
	std::string blockAccum;

	while (iss >> word)
	{
		if (!inBlock)
		{
			if (word == kStartMarker)
			{
				inBlock = true;
				blockAccum.clear();
				continue;
			}

			if (word == kHalfMarker)
			{
				current = &out.second;
				continue;
			}

			if (word == kEndMarker)
			{
				current->push_back(word);
				continue;
			}

			current->push_back(word);
		}
		else
		{
			if (word == kEndMarker)
			{
				current->push_back(blockAccum);
				inBlock = false;
				blockAccum.clear();
			}
			else
			{
				if (!blockAccum.empty())
					blockAccum += ' ';
				blockAccum += word;
			}
		}
	}

	if (inBlock && !blockAccum.empty())
		current->push_back(blockAccum);

	return out;
}

static std::string EscapeField(const std::string &s)
{
	std::string out;
	out.reserve(s.size());

	for (char c : s)
	{
		if (c == '\\')
			out += "\\\\";
		else if (c == '\t')
			out += "\\t";
		else if (c == '\n')
			out += "\\n";
		else if (c == '\r')
			out += "\\r";
		else
			out += c;
	}

	return out;
}

static std::string BuildPacket(const std::string &opcode, const std::string &id, const std::vector<std::string> &fields)
{
	std::string packet = opcode + "\t" + id;
	for (const auto &f : fields)
	{
		packet += "\t";
		packet += EscapeField(f);
	}
	return packet;
}

static std::vector<std::string> SplitTabs(const std::string &s)
{
	std::vector<std::string> parts;
	std::string cur;
	bool esc = false;

	for (char c : s)
	{
		if (esc)
		{
			if (c == 't')
				cur += '\t';
			else if (c == 'n')
				cur += '\n';
			else if (c == 'r')
				cur += '\r';
			else if (c == '\\')
				cur += '\\';
			else
				cur += c;
			esc = false;
		}
		else if (c == '\\')
		{
			esc = true;
		}
		else if (c == '\t')
		{
			parts.push_back(cur);
			cur.clear();
		}
		else
		{
			cur += c;
		}
	}

	parts.push_back(cur);
	return parts;
}

static bool ParsePositiveInt(const std::string &text, int &value)
{
	try
	{
		value = std::stoi(text);
		return value > 0;
	}
	catch (...)
	{
		value = 0;
		return false;
	}
}

static bool ExtractMovementPrefix(const ParsedHalves &halves, std::vector<std::string> &movement)
{
	if (halves.first.size() < 7)
		return false;
	movement.assign(halves.first.begin(), halves.first.begin() + 7);
	return true;
}

static bool RemoveMovementPrefix(ParsedHalves &halves, std::vector<std::string> &movement)
{
	if (!ExtractMovementPrefix(halves, movement))
		return false;
	halves.first.erase(halves.first.begin(), halves.first.begin() + 7);
	return true;
}

static void CloseOnlineSession()
{
	wo_native::SetConnected(false);
	try
	{
		if (theSocket.is_open())
			theSocket.close();
	}
	catch (...)
	{
	}
}

static void SendUdpPacket(const std::string &packet, const char *label)
{
	if (!wo_native::IsConnected() || !theSocket.is_open())
		return;

	try
	{
		theSocket.send(asio::buffer(packet));
	}
	catch (const std::exception &e)
	{
		std::cout << "Send error (" << label << "): " << e.what() << "\n";
	}
}

static std::string BuildLocalPacketId()
{
	const int localPlayerId = g_localPlayerId.load();
	if (localPlayerId > 0)
		return std::to_string(localPlayerId) + "\t" + EscapeField(GetLocalUsername());
	return EscapeField(GetLocalUsername());
}

static int g_movementSequence = static_cast<int>(((GetTickCount64() / 20ULL) % 1000000000ULL) + 1ULL);

static int g_update1Sequence = static_cast<int>(((GetTickCount64() / 20ULL) % 1000000000ULL) + 1ULL);

static int g_update2Sequence = static_cast<int>(((GetTickCount64() / 20ULL) % 1000000000ULL) + 1ULL);

static constexpr int kSequenceSpan = 2000000000;

static constexpr ULONGLONG kScriptStallThresholdMs = 750;
static constexpr ULONGLONG kKeepaliveIntervalMs = 1000;

static constexpr ULONGLONG kMenuTransitionGraceMs = 500;
static constexpr size_t kClientInGameField = 7;
static constexpr size_t kMenuNameField = 47;

static std::vector<std::string> g_cachedMovement;
static ParsedHalves g_cachedUpdate1;
static bool g_haveCachedUpdate1 = false;
static std::string g_presence = "none";
static ULONGLONG g_lastScriptActivityTick = 0;
static ULONGLONG g_lastKeepaliveTick = 0;
static ULONGLONG g_menuTransitionDeadlineTick = 0;

static void ResetTransportWatchdog()
{
	g_cachedMovement.clear();
	g_cachedUpdate1 = ParsedHalves();
	g_haveCachedUpdate1 = false;
	g_presence = "none";
	g_lastScriptActivityTick = 0;
	g_lastKeepaliveTick = 0;
	g_menuTransitionDeadlineTick = 0;
}

static bool IsTruthyField(const std::string &value)
{
	return value == "true" || value == "1" || value == "True" || value == "TRUE";
}

static bool ScriptTransportStalled(ULONGLONG now)
{
	return g_lastScriptActivityTick != 0 && now >= g_lastScriptActivityTick && (now - g_lastScriptActivityTick) >= kScriptStallThresholdMs;
}

static bool CachedClientIsInGame()
{
	return g_haveCachedUpdate1 && g_cachedUpdate1.first.size() > kClientInGameField && IsTruthyField(g_cachedUpdate1.first[kClientInGameField]);
}

static std::string EffectivePresence(ULONGLONG now)
{
	if (!g_presence.empty() && g_presence != "none")
		return g_presence;

	if (ScriptTransportStalled(now) && CachedClientIsInGame())
		return "IngameMenu";

	return "none";
}

static void ApplyPresenceToUpdate1(ParsedHalves &halves, ULONGLONG now)
{
	if (halves.first.size() <= kMenuNameField)
		return;

	const std::string presence = EffectivePresence(now);
	if (presence != "none" || ScriptTransportStalled(now))
		halves.first[kMenuNameField] = presence;
}

static int NextSequence(int &sequence)
{
	if (sequence <= 0 || sequence >= kSequenceSpan)
		sequence = 1;
	else
		++sequence;

	return sequence;
}

static int NextMovementSequence()
{
	return NextSequence(g_movementSequence);
}

static void SendMovementPacket(const std::string &packetId, const std::vector<std::string> &movement)
{
	if (movement.size() < 7)
		return;

	const int sequence = NextMovementSequence();

	std::vector<std::string> fields;
	fields.reserve(8);

	fields.push_back(std::to_string(sequence));
	fields.insert(fields.end(), movement.begin(), movement.begin() + 7);

	SendUdpPacket(BuildPacket("MOVE", packetId, fields), "MOVE");
}

static void SendMovementPayload(const std::string &payload)
{
	ParsedHalves halves = ParseValuesSplitHalf(payload);
	std::vector<std::string> movement;
	if (!ExtractMovementPrefix(halves, movement))
		return;

	g_cachedMovement = movement;
	SendMovementPacket(BuildLocalPacketId(), movement);
}

static void SendUpdate1Halves(ParsedHalves halves, ULONGLONG now)
{
	if (halves.first.size() < 7)
		return;

	ApplyPresenceToUpdate1(halves, now);

	const std::string packetId = BuildLocalPacketId();
	const int movementSequence = NextMovementSequence();
	const int updateSequence = NextSequence(g_update1Sequence);

	if (!halves.first.empty())
	{
		halves.first.insert(halves.first.begin(), std::to_string(movementSequence));

		halves.first.insert(halves.first.begin(), std::to_string(updateSequence));

		SendUdpPacket(BuildPacket("UPDATE1A", packetId, halves.first), "UPDATE1A");
	}

	if (!halves.second.empty())
	{
		halves.second.insert(halves.second.begin(), std::to_string(movementSequence));

		halves.second.insert(halves.second.begin(), std::to_string(updateSequence));

		SendUdpPacket(BuildPacket("UPDATE1B", packetId, halves.second), "UPDATE1B");
	}
}

static void SendUpdate1(const std::string &payload)
{
	ParsedHalves halves = ParseValuesSplitHalf(payload);

	if (halves.first.size() < 7)
		return;

	g_cachedMovement.assign(halves.first.begin(), halves.first.begin() + 7);

	const ULONGLONG now = GetTickCount64();

	if (halves.first.size() > kMenuNameField && !halves.first[kMenuNameField].empty())
	{
		const std::string incomingPresence = halves.first[kMenuNameField];
		const bool transitionPending = g_menuTransitionDeadlineTick != 0 && now < g_menuTransitionDeadlineTick;

		if (transitionPending && incomingPresence == "IngameMenu" && !g_presence.empty() && g_presence != "none" && g_presence != "IngameMenu")
		{
			halves.first[kMenuNameField] = g_presence;
		}
		else
		{
			g_presence = incomingPresence;
			g_menuTransitionDeadlineTick = 0;
		}
	}

	g_cachedUpdate1 = halves;
	g_haveCachedUpdate1 = true;

	SendUpdate1Halves(std::move(halves), now);
}

static void SendUpdate2(const std::string &payload)
{
	ParsedHalves halves = ParseValuesSplitHalf(payload);

	std::vector<std::string> movement;

	if (!RemoveMovementPrefix(halves, movement))
		return;

	g_cachedMovement = movement;

	const std::string packetId = BuildLocalPacketId();

	const int updateSequence = NextSequence(g_update2Sequence);

	if (!halves.first.empty())
	{
		halves.first.insert(halves.first.begin(), std::to_string(updateSequence));

		SendUdpPacket(BuildPacket("UPDATE2A", packetId, halves.first), "UPDATE2A");
	}

	if (!halves.second.empty())
	{
		halves.second.insert(halves.second.begin(), std::to_string(updateSequence));

		SendUdpPacket(BuildPacket("UPDATE2B", packetId, halves.second), "UPDATE2B");
	}
}

static void SendCombined(const std::string &payload, const char *opcode)
{
	ParsedHalves halves = ParseValuesSplitHalf(payload);
	std::vector<std::string> movement;
	if (!RemoveMovementPrefix(halves, movement))
		return;

	g_cachedMovement = movement;

	std::vector<std::string> fields;
	fields.reserve(halves.first.size() + halves.second.size());
	fields.insert(fields.end(), halves.first.begin(), halves.first.end());
	fields.insert(fields.end(), halves.second.begin(), halves.second.end());

	if (!fields.empty())
		SendUdpPacket(BuildPacket(opcode, BuildLocalPacketId(), fields), opcode);
}

// "coop <channel> <field> ...": space-separated fields (the script encodes spaces inside values)
static void SendCoop(const std::string &payload)
{
	std::vector<std::string> fields;
	std::istringstream iss(payload.substr(payload.find(' ') + 1));
	std::string word;

	while (iss >> word)
		fields.push_back(word);

	if (!fields.empty())
		SendUdpPacket(BuildPacket("COOP", BuildLocalPacketId(), fields), "COOP");
}

static std::string PayloadTag(const std::string &payload)
{
	const size_t space = payload.find(' ');
	return space == std::string::npos ? payload : payload.substr(0, space);
}

static void ProcessPresence(const std::string &payload, ULONGLONG now)
{
	const size_t space = payload.find(' ');
	std::string presence = (space == std::string::npos) ? "none" : payload.substr(space + 1);

	if (presence.empty() || presence.size() > 64)
		presence = "none";

	g_menuTransitionDeadlineTick = 0;
	g_presence = presence;

	if (g_haveCachedUpdate1 && g_cachedUpdate1.first.size() > kMenuNameField)
		g_cachedUpdate1.first[kMenuNameField] = presence;

	if (g_haveCachedUpdate1)
		SendUpdate1Halves(g_cachedUpdate1, now);
}

static void ProcessMenuTransition(const std::string &payload, ULONGLONG now)
{
	const size_t space = payload.find(' ');
	const std::string closingMenu = (space == std::string::npos) ? std::string() : payload.substr(space + 1);

	if (!closingMenu.empty() && closingMenu != g_presence)
		return;

	g_menuTransitionDeadlineTick = now + kMenuTransitionGraceMs;
}

static bool CommitDeferredMenuPresenceIfDue()
{
	if (g_menuTransitionDeadlineTick == 0)
		return false;

	const ULONGLONG now = GetTickCount64();
	if (now < g_menuTransitionDeadlineTick)
		return false;

	g_menuTransitionDeadlineTick = 0;

	if (g_presence == "IngameMenu")
		return false;

	g_presence = "IngameMenu";

	if (g_haveCachedUpdate1 && g_cachedUpdate1.first.size() > kMenuNameField)
	{
		g_cachedUpdate1.first[kMenuNameField] = g_presence;
		SendUpdate1Halves(g_cachedUpdate1, now);
		return true;
	}

	return false;
}

static bool SendTransportKeepaliveIfDue()
{
	if (!wo_native::IsConnected() || g_lastScriptActivityTick == 0)
		return false;

	const ULONGLONG now = GetTickCount64();
	if (!ScriptTransportStalled(now))
		return false;

	if (g_lastKeepaliveTick != 0 && now >= g_lastKeepaliveTick && (now - g_lastKeepaliveTick) < kKeepaliveIntervalMs)
	{
		return false;
	}

	bool sent = false;
	const std::string packetId = BuildLocalPacketId();

	if (g_cachedMovement.size() >= 7)
	{
		SendMovementPacket(packetId, g_cachedMovement);
		sent = true;
	}

	if (g_haveCachedUpdate1)
	{
		SendUpdate1Halves(g_cachedUpdate1, now);
		sent = true;
	}

	if (sent)
		g_lastKeepaliveTick = now;

	return sent;
}

static void ProcessOutbound(const std::string &payload)
{
	const std::string tag = PayloadTag(payload);

	if (tag == "offline")
	{
		ResetTransportWatchdog();
		return;
	}

	if (tag == "coop")
	{
		SendCoop(payload);
		return;
	}

	const bool scriptTransportPayload = tag == "move" || tag == "wo" || tag == "wo2" || tag == "wo3" || tag == "wo4" || tag == "presence" || tag == "presence_transition";

	if (!scriptTransportPayload)
		return;

	const ULONGLONG now = GetTickCount64();
	g_lastScriptActivityTick = now;
	g_lastKeepaliveTick = 0;

	if (tag == "move")
		SendMovementPayload(payload);
	else if (tag == "wo")
		SendUpdate1(payload);
	else if (tag == "wo2")
		SendUpdate2(payload);
	else if (tag == "wo3")
		SendCombined(payload, "UPDATE3");
	else if (tag == "wo4")
		SendCombined(payload, "UPDATE4");
	else if (tag == "presence")
		ProcessPresence(payload, now);
	else if (tag == "presence_transition")
		ProcessMenuTransition(payload, now);
}

static void QueueMovement(int playerId, const std::string &playerUsername, const std::vector<std::string> &movement)
{
	if (playerId <= 0 || playerUsername.empty() || movement.size() < 8)
		return;

	wo_native::InboundMessage message;
	message.opcode = wo_native::InboundOpcode::Move;
	message.playerId = playerId;
	message.sender = playerUsername;

	// sequence + x y z w heading speed area
	message.fields.assign(movement.begin(), movement.begin() + 8);

	wo_native::PushInbound(std::move(message));
}

static void QueueUpdate1(int playerId, const std::string &playerUsername, const std::vector<std::string> &update1A, const std::vector<std::string> &update1B)
{
	if (playerId <= 0 || playerUsername.empty())
		return;

	wo_native::InboundMessage message;
	message.opcode = wo_native::InboundOpcode::Update1;
	message.playerId = playerId;
	message.sender = playerUsername;
	message.fields.reserve(update1A.size() + update1B.size());
	message.fields.insert(message.fields.end(), update1A.begin(), update1A.end());
	message.fields.insert(message.fields.end(), update1B.begin(), update1B.end());

	if (!message.fields.empty())
		wo_native::PushInbound(std::move(message));
}

static void QueueUpdate2(int playerId, const std::string &playerUsername, const std::vector<std::string> &update2A, const std::vector<std::string> &update2B)
{
	if (playerId <= 0 || playerUsername.empty())
		return;

	wo_native::InboundMessage message;
	message.opcode = wo_native::InboundOpcode::Update2;
	message.playerId = playerId;
	message.sender = playerUsername;
	message.fields.reserve(update2A.size() + update2B.size());
	message.fields.insert(message.fields.end(), update2A.begin(), update2A.end());
	message.fields.insert(message.fields.end(), update2B.begin(), update2B.end());

	if (!message.fields.empty())
		wo_native::PushInbound(std::move(message));
}

static void QueueUpdate3(int playerId, const std::string &playerUsername, std::vector<std::string> &&fields)
{
	if (playerId <= 0 || playerUsername.empty() || fields.size() < 6)
		return;

	wo_native::InboundMessage message;
	message.opcode = wo_native::InboundOpcode::Update3;
	message.playerId = playerId;
	message.sender = playerUsername;
	message.fields = std::move(fields);
	wo_native::PushInbound(std::move(message));
}

static void QueueUpdate4(int playerId, const std::string &playerUsername, std::vector<std::string> &&fields)
{
	if (playerId <= 0 || playerUsername.empty() || fields.size() < 16)
		return;

	wo_native::InboundMessage message;
	message.opcode = wo_native::InboundOpcode::Update4;
	message.playerId = playerId;
	message.sender = playerUsername;
	message.fields = std::move(fields);
	wo_native::PushInbound(std::move(message));
}

static void ResetHandshake()
{
	g_welcomed.store(false);
	g_helloAttemptsSent.store(0);
	g_lastHelloTick.store(0);
}

static void SendHelloIfDue()
{
	if (g_welcomed.load() || !wo_native::IsConnected())
		return;

	const ULONGLONG now = GetTickCount64();
	const ULONGLONG last = g_lastHelloTick.load();
	if (last != 0 && now - last < kHelloIntervalMs)
		return;

	const int sent = g_helloAttemptsSent.load();
	if (sent >= kHelloAttempts)
	{
		if (sent == kHelloAttempts)
		{
			wo_native::DebugLog("handshake: the server never answered HELLO (a server older than W3Coop " + std::string(kModVersion) + "?); playing on without a version check");
			g_helloAttemptsSent.store(sent + 1);
		}
		return;
	}

	g_lastHelloTick.store(now);
	g_helloAttemptsSent.store(sent + 1);
	SendUdpPacket("HELLO\t" + EscapeField(GetLocalUsername()) + "\t" + kProtocolVersion + "\t" + kModVersion + "\t" + g_gameVersion, "HELLO");
}

static bool TryRenameAfterTaken()
{
	const ULONGLONG now = GetTickCount64();

	// packets sent under the old name are still answered with USERNAME_TAKEN for a moment
	if (g_lastRenameTick != 0 && now - g_lastRenameTick < kRenameSettleMs)
		return true;

	if (g_renames >= kMaxRenames)
		return false;

	++g_renames;
	g_lastRenameTick = now;

	std::string base = g_baseUsername;
	if (base.length() > 14)
		base.resize(14);
	const std::string renamed = base + std::to_string(g_renames + 1);

	wo_native::DebugLog("username " + GetLocalUsername() + " is taken on this server; playing as " + renamed);
	SetLocalUsername(renamed);
	g_localPlayerId.store(0);
	wo_native::SetLocalId(0);
	ResetHandshake();
	return true;
}

static bool g_sendCrashReports = true;
static ULONGLONG g_lastCrashHandlerCheck = 0;
static constexpr ULONGLONG kCrashHandlerCheckMs = 30000;

// the game installs its own crash handler some time after startup; keep W3Coop's in front of it (it chains on)
static void ReinstallCrashHandlerIfDue()
{
	const ULONGLONG now = GetTickCount64();
	if (now - g_lastCrashHandlerCheck < kCrashHandlerCheckMs)
		return;
	g_lastCrashHandlerCheck = now;
	wo_crash::Reinstall();
}

// the host answered the handshake: it is the one to collect crash reports from earlier sessions
static void OnWelcome()
{
	if (!g_sendCrashReports || g_crashReportPort <= 0)
		return;

	std::string host = ip;
	try
	{
		host = serverEndpoint.address().to_string();
	}
	catch (...)
	{
	}
	wo_crash::UploadPending(host, g_crashReportPort, GetLocalUsername());
}

// Connection watchdog: the server repeats state every 100 ms (33 ms on LAN), so a few seconds of silence means the
// host is gone or the network dropped. The player is told, and told again when packets come back.
static constexpr ULONGLONG kConnectionLostMs = 6000;
static std::atomic<ULONGLONG> g_lastServerPacketTick{0};
static std::atomic<bool> g_connectionLost{false};

static void CheckConnection()
{
	const ULONGLONG last = g_lastServerPacketTick.load();
	if (!wo_native::IsConnected() || last == 0 || g_connectionLost.load())
		return;

	if (GetTickCount64() - last > kConnectionLostMs)
	{
		g_connectionLost.store(true);
		wo_native::DebugLog("connection: nothing from the server for " + std::to_string(kConnectionLostMs / 1000) + " s");
		wo_native::PushControl(wo_native::InboundOpcode::ConnectionLost);
	}
}

static void NoteServerPacket()
{
	g_lastServerPacketTick.store(GetTickCount64());
	if (g_connectionLost.exchange(false))
	{
		wo_native::DebugLog("connection: the server answers again");
		wo_native::PushControl(wo_native::InboundOpcode::ConnectionRestored);
	}
}

// Co-op kill switch: Ctrl+F9 while the game window is in front. Polled, so no input files of the game change.
static bool g_killSwitchDown = false;

static void PollKillSwitchHotkey()
{
	HWND front = GetForegroundWindow();
	DWORD pid = 0;
	if (front)
		GetWindowThreadProcessId(front, &pid);

	const bool down = pid == GetCurrentProcessId() && (GetAsyncKeyState(VK_CONTROL) & 0x8000) && (GetAsyncKeyState(VK_F9) & 0x8000);
	if (down && !g_killSwitchDown)
	{
		wo_native::DebugLog("kill switch: Ctrl+F9");
		wo_native::PushControl(wo_native::InboundOpcode::ToggleCoop);
	}
	g_killSwitchDown = down;
}

static void HandleServerPacket(const std::string &msg)
{
	auto parts = SplitTabs(msg);
	if (parts.empty())
		return;

	NoteServerPacket();

	// "HOST \t username": a server started with --lan names the player on the PC that runs it
	if (parts[0] == "HOST")
	{
		if (parts.size() >= 2)
			wo_native::SetHostName(parts[1]);
		return;
	}

	if (parts[0] == "WELCOME")
	{
		if (!g_welcomed.exchange(true))
		{
			wo_native::DebugLog("handshake: host runs W3Coop " + (parts.size() >= 2 ? parts[1] : std::string("?")) + ", same as this game");
			// "WELCOME \t modVersion \t protocol \t crashReportPort [\t host]" (port 0: the host takes no crash reports;
			// host: the player on the server's PC, when the server runs with --lan)
			int crashPort = 0;
			if (parts.size() >= 4 && ParsePositiveInt(parts[3], crashPort))
				g_crashReportPort = crashPort;
			if (parts.size() >= 5 && !parts[4].empty())
				wo_native::SetHostName(parts[4]);
			OnWelcome();
		}
		return;
	}

	if (parts[0] == "ERROR")
	{
		if (parts.size() >= 2 && parts[1] == "USERNAME_TAKEN")
		{
			if (TryRenameAfterTaken())
				return;
			wo_native::PushControl(wo_native::InboundOpcode::UsernameTaken);
		}
		else if (parts.size() >= 2 && (parts[1] == "VERSION_MISMATCH" || parts[1] == "GAME_VERSION_MISMATCH"))
		{
			const bool game = parts[1] == "GAME_VERSION_MISMATCH";
			const std::string hostVersion = parts.size() >= 3 ? parts[2] : std::string("unknown");
			const std::string mine = game ? g_gameVersion : std::string(kModVersion);
			wo_native::DebugLog(std::string("handshake: ") + (game ? "game" : "W3Coop") + " version mismatch: host has " + hostVersion + ", this game has " + mine);
			wo_native::PushControl(wo_native::InboundOpcode::VersionMismatch, {game ? "game" : "mod", hostVersion, mine});
		}
		else if (parts.size() >= 2 && parts[1] == "BANNED")
			wo_native::PushControl(wo_native::InboundOpcode::Banned);
		else if (parts.size() >= 2 && parts[1] == "NOT_WHITELISTED")
			wo_native::PushControl(wo_native::InboundOpcode::NotWhitelisted);
		CloseOnlineSession();
		return;
	}

	if (parts[0] == "KICK")
	{
		wo_native::PushControl(wo_native::InboundOpcode::Kicked);
		CloseOnlineSession();
		return;
	}

	const std::string &opcode = parts[0];
	if (opcode != "MOVE" && opcode != "UPDATE1A" && opcode != "UPDATE1B" && opcode != "UPDATE2A" && opcode != "UPDATE2B" && opcode != "UPDATE3" && opcode != "UPDATE4" && opcode != "COOP")
	{
		return;
	}

	if (parts.size() < 3)
		return;

	int playerId = 0;
	if (!ParsePositiveInt(parts[1], playerId))
		return;

	std::string playerUsername = parts[2];
	if (playerUsername.empty())
		return;

	if (playerUsername == GetLocalUsername())
	{
		g_localPlayerId.store(playerId);
		wo_native::SetLocalId(playerId);
	}

	std::vector<std::string> fields(parts.begin() + 3, parts.end());

	if (opcode == "COOP")
	{
		if (fields.empty() || fields[0].empty())
			return;

		// scripts send spaces inside values as '*' (fields are space-separated); restore them here so
		// WO_NameAt yields names that contain spaces, like journal tags
		for (auto &field : fields)
			std::replace(field.begin(), field.end(), '*', ' ');

		{
			std::lock_guard<std::mutex> lock(remoteMu);
			auto &rp = remotePlayers[playerId];
			rp.username = playerUsername;
			auto &last = rp.lastCoop[fields[0]];
			if (fields == last)
				return;
			last = fields;
		}

		wo_native::InboundMessage message;
		message.opcode = wo_native::InboundOpcode::Coop;
		message.playerId = playerId;
		message.sender = playerUsername;
		message.fields = std::move(fields);
		wo_native::PushInbound(std::move(message));
		return;
	}

	if (opcode == "MOVE")
	{
		QueueMovement(playerId, playerUsername, fields);
		return;
	}

	if (fields.empty())
		return;

	int packetSequence = 0;
	int movementSequence = 0;

	if (opcode == "UPDATE1A" || opcode == "UPDATE1B" || opcode == "UPDATE2A" || opcode == "UPDATE2B")
	{
		if (fields.empty() || !ParsePositiveInt(fields[0], packetSequence))
		{
			return;
		}

		fields.erase(fields.begin());
	}

	if (opcode == "UPDATE1A" || opcode == "UPDATE1B")
	{
		if (fields.empty() || !ParsePositiveInt(fields[0], movementSequence))
		{
			return;
		}

		fields.erase(fields.begin());
	}

	if (opcode == "UPDATE3" || opcode == "UPDATE4")
	{
		bool changed = false;
		{
			std::lock_guard<std::mutex> lock(remoteMu);
			auto &rp = remotePlayers[playerId];
			rp.username = playerUsername;
			std::vector<std::string> &last = (opcode == "UPDATE3") ? rp.lastUpdate3 : rp.lastUpdate4;
			if (fields != last)
			{
				last = fields;
				changed = true;
			}
		}

		if (!changed)
			return;

		if (opcode == "UPDATE3")
			QueueUpdate3(playerId, playerUsername, std::move(fields));
		else
			QueueUpdate4(playerId, playerUsername, std::move(fields));
		return;
	}

	bool push1 = false;
	bool push2 = false;
	std::vector<std::string> u1a;
	std::vector<std::string> u1b;
	std::vector<std::string> u2a;
	std::vector<std::string> u2b;
	std::string pushUsername;

	{
		std::lock_guard<std::mutex> lock(remoteMu);
		auto &rp = remotePlayers[playerId];
		rp.username = playerUsername;

		if (opcode == "UPDATE1A" && packetSequence > rp.lastPushed1Sequence)
		{
			rp.update1A = std::move(fields);
			rp.update1ASequence = packetSequence;
			rp.update1AMovementSequence = movementSequence;
		}
		else if (opcode == "UPDATE1B" && packetSequence > rp.lastPushed1Sequence)
		{
			rp.update1B = std::move(fields);
			rp.update1BSequence = packetSequence;
			rp.update1BMovementSequence = movementSequence;
		}
		else if (opcode == "UPDATE2A" && packetSequence > rp.lastPushed2Sequence)
		{
			rp.update2A = std::move(fields);
			rp.update2ASequence = packetSequence;
		}
		else if (opcode == "UPDATE2B" && packetSequence > rp.lastPushed2Sequence)
		{
			rp.update2B = std::move(fields);
			rp.update2BSequence = packetSequence;
		}

		if (rp.update1ASequence > rp.lastPushed1Sequence && rp.update1ASequence == rp.update1BSequence && rp.update1AMovementSequence == rp.update1BMovementSequence)
		{
			rp.lastPushed1Sequence = rp.update1ASequence;

			u1a = rp.update1A;
			u1b = rp.update1B;

			pushUsername = rp.username;
			push1 = true;
		}

		if (rp.update2ASequence > rp.lastPushed2Sequence && rp.update2ASequence == rp.update2BSequence)
		{
			rp.lastPushed2Sequence = rp.update2ASequence;

			u2a = rp.update2A;
			u2b = rp.update2B;

			pushUsername = rp.username;
			push2 = true;
		}
	}

	if (push1)
		QueueUpdate1(playerId, pushUsername, u1a, u1b);
	if (push2)
		QueueUpdate2(playerId, pushUsername, u2a, u2b);
}

static void SenderThread()
{
	std::string payload;
	bool wasConnected = false;

	while (g_run.load())
	{
		bool worked = false;
		const bool connected = wo_native::IsConnected();

		if (connected && !wasConnected)
			ResetTransportWatchdog();
		else if (!connected && wasConnected)
			ResetTransportWatchdog();

		wasConnected = connected;

		while (g_run.load() && wo_native::PopOutbound(payload))
		{
			if (wo_native::IsConnected())
				ProcessOutbound(payload);
			worked = true;
		}

		if (wo_native::IsConnected() && CommitDeferredMenuPresenceIfDue())
			worked = true;

		if (wo_native::IsConnected() && SendTransportKeepaliveIfDue())
			worked = true;

		SendHelloIfDue();
		ReinstallCrashHandlerIfDue();
		CheckConnection();
		PollKillSwitchHotkey();

		if (!worked)
			Sleep(1);
	}
}

static void ReceiverThread()
{
	std::vector<char> data(8192);

	while (g_run.load())
	{
		try
		{
			asio::ip::udp::endpoint senderEndpoint;
			std::size_t len = theSocket.receive_from(asio::buffer(data), senderEndpoint);
			std::string msg(data.data(), len);
			HandleServerPacket(msg);
		}
		catch (const std::exception &e)
		{
			if (g_run.load() && wo_native::IsConnected())
				std::cout << "Receive error: " << e.what() << "\n";

			if (g_run.load())
				Sleep(500);
		}
	}
}

static void connectServer()
{
	if (g_shutdown.load())
		return;

	try
	{
		g_run.store(true);
		theSocket.open(asio::ip::udp::v4());
		theSocket.bind(asio::ip::udp::endpoint(asio::ip::udp::v4(), 0));
		serverEndpoint = *resolver.resolve(asio::ip::udp::v4(), ip, port).begin();
		theSocket.connect(serverEndpoint);
		wo_native::SetConnected(true);

		// These workers are process-lifetime. Detaching avoids std::thread global
		// destruction/join work during DLL_PROCESS_DETACH. The module is pinned, so
		// their code cannot be unloaded while they are running.
		std::thread(SenderThread).detach();
		std::thread(ReceiverThread).detach();
	}
	catch (const std::exception &e)
	{
		wo_native::SetConnected(false);
		std::cout << "Connection error: " << e.what() << "\n";
	}
}

static std::string GetEnv(const char *name)
{
	char *value = nullptr;
	size_t length = 0;
	if (_dupenv_s(&value, &length, name) != 0 || !value)
		return std::string();

	std::string out(value);
	free(value);
	return out;
}

// "5.0.15.65482": the exe's version resource (the handshake refuses two players on different game builds)
static std::string GameExeVersion()
{
	wchar_t path[MAX_PATH]{};
	if (GetModuleFileNameW(nullptr, path, MAX_PATH) == 0)
		return "unknown";

	DWORD ignored = 0;
	const DWORD bytes = GetFileVersionInfoSizeW(path, &ignored);
	if (bytes == 0)
		return "unknown";

	std::vector<uint8_t> data(bytes);
	VS_FIXEDFILEINFO *info = nullptr;
	UINT infoSize = 0;
	if (!GetFileVersionInfoW(path, 0, bytes, data.data()) || !VerQueryValueW(data.data(), L"\\", reinterpret_cast<LPVOID *>(&info), &infoSize) || !info)
		return "unknown";

	return std::to_string(HIWORD(info->dwFileVersionMS)) + "." + std::to_string(LOWORD(info->dwFileVersionMS)) + "." + std::to_string(HIWORD(info->dwFileVersionLS)) + "." +
	       std::to_string(LOWORD(info->dwFileVersionLS));
}

// ServerIP "auto": broadcast "DISCOVER \t W3COOP \t protocol" on the LAN and take the first host that answers
// "W3COOP_HOST \t protocol \t modVersion \t port \t players". The answer is a unicast reply to a broadcast, which
// Windows Firewall lets in by default, so the joining PC needs no firewall rule.
static constexpr int kDiscoverySeconds = 180;

static bool DiscoverLanHost(std::string &hostIp, std::string &hostPort)
{
	int searchPort = 0;
	if (!ParsePositiveInt(port, searchPort) || searchPort > 65535)
		searchPort = 40000;

	try
	{
		asio::io_context context;
		asio::ip::udp::socket probe(context);
		probe.open(asio::ip::udp::v4());
		probe.set_option(asio::socket_base::broadcast(true));
		probe.bind(asio::ip::udp::endpoint(asio::ip::udp::v4(), 0));

		DWORD timeoutMs = 500;
		setsockopt(probe.native_handle(), SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char *>(&timeoutMs), sizeof(timeoutMs));

		const std::string query = std::string("DISCOVER\tW3COOP\t") + kProtocolVersion;
		const asio::ip::udp::endpoint broadcast(asio::ip::address_v4::broadcast(), static_cast<unsigned short>(searchPort));
		std::vector<char> data(1024);

		wo_native::DebugLog("discovery: looking for a W3Coop host on the LAN (UDP " + std::to_string(searchPort) + ")");
		for (int second = 0; second < kDiscoverySeconds && !g_shutdown.load(); ++second)
		{
			asio::error_code sendError;
			probe.send_to(asio::buffer(query), broadcast, 0, sendError);

			for (int wait = 0; wait < 2; ++wait)
			{
				asio::ip::udp::endpoint from;
				asio::error_code receiveError;
				const std::size_t length = probe.receive_from(asio::buffer(data), from, 0, receiveError);
				if (receiveError)
					continue;

				const auto parts = SplitTabs(std::string(data.data(), length));
				if (parts.size() >= 4 && parts[0] == "W3COOP_HOST")
				{
					hostIp = from.address().to_string();
					hostPort = parts[3];
					wo_native::DebugLog("discovery: found host " + hostIp + ":" + hostPort + " (W3Coop " + parts[2] + ")");
					return true;
				}
			}
		}
	}
	catch (const std::exception &e)
	{
		wo_native::DebugLog(std::string("discovery failed: ") + e.what());
	}

	wo_native::DebugLog("discovery: no host answered within " + std::to_string(kDiscoverySeconds) + " s; set ServerIP to the host's address in config.xml");
	return false;
}

static std::string SanitizeUsername(const std::string &user)
{
	std::string out = std::regex_replace(user, std::regex("[^A-Za-z0-9_]"), "");

	if (out.length() > 16)
		out.resize(16);

	if (out.length() < 2 || out == "none")
		out = "Player";

	return out;
}

static void initScript()
{
	fs::path baseDir = getExecutablePath();
	fs::path woDir = baseDir / "WitcherOnline";

	fs::create_directories(woDir);

	// WO_USERNAME / WO_SERVER_IP / WO_SERVER_PORT override config.xml, so several game instances can share one install.
	const std::string envUsername = GetEnv("WO_USERNAME");
	const std::string envIp = GetEnv("WO_SERVER_IP");
	const std::string envPort = GetEnv("WO_SERVER_PORT");

	const std::string logName = envUsername.empty() ? "WitcherOnline.log" : "WitcherOnline_" + SanitizeUsername(envUsername) + ".log";

	fs::path fullPath = woDir / "config.xml";

	pugi::xml_document doc;
	pugi::xml_parse_result result = doc.load_file(fullPath.c_str());

	std::string configuredName;
	std::string lanRole;
	std::string autoLoadSave;
	if (result)
	{
		pugi::xml_node xml = doc.child("Config");
		if (xml)
		{
			configuredName = xml.child("Username").text().as_string();
			ip = xml.child("ServerIP").text().as_string();
			port = xml.child("Port").text().as_string();
			if (xml.child("SendCrashReports"))
				g_sendCrashReports = xml.child("SendCrashReports").text().as_bool(true);
			// written by the LAN launchers: "host" or "member", and the save "Join LAN co-op.cmd" brought over
			lanRole = xml.child("Role").text().as_string();
			autoLoadSave = xml.child("AutoLoadSave").text().as_string();
		}
	}
	if (lanRole != "host" && lanRole != "member")
		lanRole.clear();
	wo_native::SetLanInfo(lanRole, autoLoadSave);

	// the package's default "Player" becomes the Windows account name, so two PCs don't start out with the same name
	if (configuredName.empty() || configuredName == "Player")
		configuredName = GetEnv("USERNAME");
	username = SanitizeUsername(configuredName);

	if (!envUsername.empty())
		username = SanitizeUsername(envUsername);
	if (!envIp.empty())
		ip = envIp;
	if (!envPort.empty())
		port = envPort;

	g_baseUsername = username;
	g_gameVersion = GameExeVersion();

	// before the log opens: keeps the last session's log and files a report if that session never exited cleanly
	wo_crash::Install(woDir, logName, {username, kModVersion, g_gameVersion, ip + ":" + port});

	wo_native::InitLog((woDir / logName).string());

	wo_native::DebugLog("startup: W3Coop " + std::string(kModVersion) + " (protocol " + kProtocolVersion + "), game " + g_gameVersion);
	wo_native::DebugLog("username=" + username + " server=" + ip + ":" + port + (lanRole.empty() ? "" : " LAN role=" + lanRole) +
	                    (autoLoadSave.empty() ? "" : " save to load=" + autoLoadSave));
	if (!wo_profile::Documents().empty())
		wo_native::DebugLog("co-op profile: Documents -> " + fs::path(wo_profile::Documents()).u8string());

	SetLocalUsername(username);

	if (!wo_native::RegisterNatives())
	{
		wo_native::DebugLog("failed to register WitcherOnline native functions");
		return;
	}

	if (ip == "auto" || ip == "lan")
	{
		std::string foundIp, foundPort;
		if (DiscoverLanHost(foundIp, foundPort))
		{
			ip = foundIp;
			port = foundPort;
		}
		else
		{
			ip = "127.0.0.1";
			wo_native::PushControl(wo_native::InboundOpcode::NoHostFound);
		}
	}

	connectServer();
}

static DWORD WINAPI InitThreadProc(LPVOID)
{
	if (g_shutdown.load())
		return 0;

	// WitcherOnline owns long-lived networking workers. Keep the ASI loaded for
	// the process lifetime so an ASI loader cannot FreeLibrary it underneath them.
	PinClientModule();

	initScript();
	return 0;
}

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID)
{
	switch (reason)
	{
	case DLL_PROCESS_ATTACH:
		DisableThreadLibraryCalls(hModule);
		// here, not on the init thread: the game may ask for its Documents folder before that thread runs
		wo_profile::InstallIfConfigured(getExecutablePath() / "WitcherOnline");
		g_initThread = CreateThread(nullptr, 0, InitThreadProc, nullptr, 0, nullptr);
		if (g_initThread)
		{
			CloseHandle(g_initThread);
			g_initThread = NULL;
		}
		break;

	case DLL_PROCESS_DETACH:
		wo_crash::MarkCleanExit();
		break;
	}

	return TRUE;
}