#include "crash.h"
#include "NativeBridge.h"
#include "pch.h"

#include <windows.h>

#include <dbghelp.h>
#include <winhttp.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <fstream>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

#pragma comment(lib, "dbghelp.lib")
#pragma comment(lib, "winhttp.lib")

namespace fs = std::filesystem;

namespace wo_crash
{
	static constexpr uintmax_t kMaxUploadBytes = 512ull * 1024 * 1024;
	static constexpr int kMaxGameDumps = 2;

	static fs::path g_reportsDir;
	static fs::path g_logPath;
	static SessionInfo g_info;
	// the handler runs in a crashed process: everything it needs is prepared up front
	static std::wstring g_reportsDirW;
	static std::wstring g_logPathW;
	static std::wstring g_markerW;
	static std::string g_sessionText;

	static LPTOP_LEVEL_EXCEPTION_FILTER g_previousFilter = nullptr;
	static std::atomic<bool> g_installed{false};
	static std::atomic<bool> g_inHandler{false};
	static std::atomic<bool> g_uploading{false};

	static std::string Timestamp()
	{
		SYSTEMTIME t{};
		GetLocalTime(&t);
		char text[32]{};
		sprintf_s(text, sizeof(text), "%04u%02u%02u-%02u%02u%02u", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
		return text;
	}

	static std::string SafeName(const std::string &name)
	{
		std::string out;
		for (char c : name)
			out += (isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '-' || c == '.') ? c : '_';
		return out.empty() ? std::string("unnamed") : out;
	}

	// path::string() throws on names the ANSI code page can't hold; UTF-8 holds them all
	static std::string Utf8(const fs::path &path)
	{
		const std::wstring wide = path.wstring();
		const int bytes = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
		std::string out(bytes > 0 ? bytes : 0, '\0');
		if (bytes > 0)
			WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), out.data(), bytes, nullptr, nullptr);
		return out;
	}

	static void WriteText(const fs::path &path, const std::string &text)
	{
		std::ofstream file(path, std::ios::binary | std::ios::trunc);
		file << text;
	}

	static std::string ReadText(const fs::path &path)
	{
		std::ifstream file(path, std::ios::binary);
		std::ostringstream text;
		text << file.rdbuf();
		return text.str();
	}

	static std::string BuildSessionText()
	{
		SYSTEMTIME t{};
		GetLocalTime(&t);
		char started[32]{};
		sprintf_s(started, sizeof(started), "%04u-%02u-%02u %02u:%02u:%02u", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);

		std::ostringstream text;
		text << "player: " << g_info.username << "\r\n"
		     << "W3Coop: " << g_info.modVersion << "\r\n"
		     << "game: " << g_info.gameVersion << "\r\n"
		     << "server: " << g_info.server << "\r\n"
		     << "session started: " << started << "\r\n"
		     << "process id: " << GetCurrentProcessId() << "\r\n";
		return text.str();
	}

	// crash dumps the game or Windows Error Reporting wrote since the session began
	static void CopyGameDumps(const fs::path &into, fs::file_time_type since)
	{
		std::vector<fs::path> roots;
		const fs::path bin = g_reportsDir.parent_path().parent_path();
		roots.push_back(bin.parent_path());
		roots.push_back(bin / "x64_dx12");
		char localAppData[MAX_PATH]{};
		if (GetEnvironmentVariableA("LOCALAPPDATA", localAppData, MAX_PATH) > 0)
			roots.push_back(fs::path(localAppData) / "CrashDumps");

		std::vector<std::pair<fs::file_time_type, fs::path>> dumps;
		for (const fs::path &root : roots)
		{
			std::error_code ec;
			for (fs::directory_iterator it(root, ec), end; !ec && it != end; it.increment(ec))
			{
				const auto &entry = *it;
				// wide names: path::string() throws on a name the ANSI code page can't hold
				std::wstring name = entry.path().filename().wstring();
				std::transform(name.begin(), name.end(), name.begin(), [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
				if (!entry.is_regular_file(ec) || name.size() < 4 || name.compare(name.size() - 4, 4, L".dmp") != 0)
					continue;
				if (root.filename() == L"CrashDumps" && name.rfind(L"witcher3", 0) != 0)
					continue;
				const auto written = entry.last_write_time(ec);
				if (!ec && written >= since)
					dumps.emplace_back(written, entry.path());
			}
		}

		std::sort(dumps.begin(), dumps.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
		int copied = 0;
		for (const auto &dump : dumps)
		{
			std::error_code ec;
			if (copied >= kMaxGameDumps || fs::file_size(dump.second, ec) > kMaxUploadBytes)
				continue;
			fs::copy_file(dump.second, into / (L"game-" + dump.second.filename().wstring()), fs::copy_options::overwrite_existing, ec);
			if (!ec)
				++copied;
		}
	}

	static void ReportUncleanExit(const fs::path &marker, const fs::path &previousLog)
	{
		std::error_code ec;
		const auto since = fs::last_write_time(marker, ec);
		const fs::path dir = g_reportsDir / (Timestamp() + "-no-clean-exit");
		fs::create_directories(dir, ec);

		WriteText(dir / "report.txt", "The previous session did not exit cleanly: the game froze and was closed, or it crashed "
		                              "into another crash handler than W3Coop's.\r\n\r\nPrevious session:\r\n" +
		                                  ReadText(marker));
		if (fs::exists(previousLog, ec))
			fs::copy_file(previousLog, dir / "WitcherOnline.log", fs::copy_options::overwrite_existing, ec);
		if (!ec)
			CopyGameDumps(dir, since);
	}

	static std::string ModuleOf(void *address, uintptr_t &offset)
	{
		HMODULE module = nullptr;
		offset = reinterpret_cast<uintptr_t>(address);
		if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, static_cast<LPCSTR>(address), &module) || !module)
			return "unknown module";

		char path[MAX_PATH]{};
		GetModuleFileNameA(module, path, MAX_PATH);
		offset = reinterpret_cast<uintptr_t>(address) - reinterpret_cast<uintptr_t>(module);
		return fs::path(path).filename().string();
	}

	static void WriteCrashReport(EXCEPTION_POINTERS *exception)
	{
		const std::string stamp = Timestamp();
		const std::wstring dir = g_reportsDirW + L"\\" + std::wstring(stamp.begin(), stamp.end()) + L"-crash";
		CreateDirectoryW(dir.c_str(), nullptr);

		HANDLE dump = CreateFileW((dir + L"\\crash.dmp").c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
		BOOL dumped = FALSE;
		if (dump != INVALID_HANDLE_VALUE)
		{
			MINIDUMP_EXCEPTION_INFORMATION info{};
			info.ThreadId = GetCurrentThreadId();
			info.ExceptionPointers = exception;
			info.ClientPointers = FALSE;
			const auto type = static_cast<MINIDUMP_TYPE>(MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules | MiniDumpWithIndirectlyReferencedMemory);
			dumped = MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), dump, type, exception ? &info : nullptr, nullptr, nullptr);
			CloseHandle(dump);
		}

		std::ostringstream text;
		if (exception && exception->ExceptionRecord)
		{
			const EXCEPTION_RECORD *record = exception->ExceptionRecord;
			uintptr_t offset = 0;
			const std::string module = ModuleOf(record->ExceptionAddress, offset);
			char line[256]{};
			sprintf_s(line, sizeof(line), "exception 0x%08lX at %s+0x%llX (thread %lu)\r\n", record->ExceptionCode, module.c_str(),
			          static_cast<unsigned long long>(offset), GetCurrentThreadId());
			text << line;
			if (record->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && record->NumberParameters >= 2)
			{
				sprintf_s(line, sizeof(line), "access violation: %s 0x%llX\r\n", record->ExceptionInformation[0] == 0 ? "read of" : (record->ExceptionInformation[0] == 1 ? "write to" : "execute at"),
				          static_cast<unsigned long long>(record->ExceptionInformation[1]));
				text << line;
			}
		}
		text << "minidump: " << (dumped ? "crash.dmp" : "could not be written") << "\r\n\r\nSession:\r\n" << g_sessionText;

		HANDLE report = CreateFileW((dir + L"\\report.txt").c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
		if (report != INVALID_HANDLE_VALUE)
		{
			const std::string body = text.str();
			DWORD written = 0;
			WriteFile(report, body.data(), static_cast<DWORD>(body.size()), &written, nullptr);
			CloseHandle(report);
		}

		CopyFileW(g_logPathW.c_str(), (dir + L"\\WitcherOnline.log").c_str(), FALSE);
	}

	static LONG WINAPI CrashFilter(EXCEPTION_POINTERS *exception)
	{
		// another handler that chains back to this one ends here instead of looping
		if (g_inHandler.exchange(true))
			return EXCEPTION_CONTINUE_SEARCH;

		WriteCrashReport(exception);
		// reported: the next start doesn't file a second "no clean exit" report for this session
		DeleteFileW(g_markerW.c_str());

		const LPTOP_LEVEL_EXCEPTION_FILTER next = g_previousFilter;
		const LONG result = next ? next(exception) : EXCEPTION_CONTINUE_SEARCH;
		g_inHandler.store(false);
		return result;
	}

	static void InstallUnguarded(const fs::path &woDir, const std::string &logName, const SessionInfo &info)
	{
		g_info = info;
		g_reportsDir = woDir / "crash-reports";
		g_logPath = woDir / logName;
		const fs::path marker = woDir / (fs::path(logName).stem().wstring() + L".running");
		const fs::path previousLog = woDir / (fs::path(logName).stem().wstring() + L".prev.log");
		g_reportsDirW = g_reportsDir.wstring();
		g_logPathW = g_logPath.wstring();
		g_markerW = marker.wstring();

		std::error_code ec;
		fs::create_directories(g_reportsDir, ec);
		// the last session's report is a bonus: whatever goes wrong there, the crash handler still goes in
		try
		{
			if (fs::exists(g_logPath, ec))
			{
				fs::remove(previousLog, ec);
				fs::rename(g_logPath, previousLog, ec);
			}
			if (fs::exists(marker, ec))
				ReportUncleanExit(marker, previousLog);
		}
		catch (...)
		{
		}

		g_sessionText = BuildSessionText();
		WriteText(marker, g_sessionText);

		g_previousFilter = SetUnhandledExceptionFilter(&CrashFilter);
		g_installed.store(true);
	}

	// runs in the game at startup: a problem with the reports must never take the game down
	void Install(const fs::path &woDir, const std::string &logName, const SessionInfo &info)
	{
		try
		{
			InstallUnguarded(woDir, logName, info);
		}
		catch (...)
		{
			if (!g_installed.load() && !g_reportsDirW.empty())
			{
				g_previousFilter = SetUnhandledExceptionFilter(&CrashFilter);
				g_installed.store(true);
			}
		}
	}

	void Reinstall()
	{
		if (!g_installed.load())
			return;

		const LPTOP_LEVEL_EXCEPTION_FILTER current = SetUnhandledExceptionFilter(&CrashFilter);
		if (current != &CrashFilter && current != nullptr)
		{
			g_previousFilter = current;
			wo_native::DebugLog("crash: the game replaced the crash handler; W3Coop's is in front again and passes crashes on to it");
		}
	}

	void MarkCleanExit()
	{
		if (g_installed.load())
			DeleteFileW(g_markerW.c_str());
	}

	static bool PostFile(const std::wstring &host, int port, const std::wstring &path, const std::vector<char> &body, std::string &error)
	{
		bool ok = false;
		DWORD status = 0;
		HINTERNET session = WinHttpOpen(L"W3Coop-crash-report/1", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
		HINTERNET connection = session ? WinHttpConnect(session, host.c_str(), static_cast<INTERNET_PORT>(port), 0) : nullptr;
		HINTERNET request = connection ? WinHttpOpenRequest(connection, L"POST", path.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0) : nullptr;

		if (request)
		{
			WinHttpSetTimeouts(request, 5000, 5000, 60000, 60000);
			LPVOID data = body.empty() ? WINHTTP_NO_REQUEST_DATA : const_cast<char *>(body.data());
			if (WinHttpSendRequest(request, L"Content-Type: application/octet-stream\r\n", static_cast<DWORD>(-1L), data, static_cast<DWORD>(body.size()),
			                       static_cast<DWORD>(body.size()), 0) &&
			    WinHttpReceiveResponse(request, nullptr))
			{
				DWORD size = sizeof(status);
				WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX);
				ok = status >= 200 && status < 300;
			}
		}

		if (!ok)
			error = status != 0 ? "HTTP " + std::to_string(status) : "WinHTTP error " + std::to_string(GetLastError());

		if (request)
			WinHttpCloseHandle(request);
		if (connection)
			WinHttpCloseHandle(connection);
		if (session)
			WinHttpCloseHandle(session);
		return ok;
	}

	static void UploadAllUnguarded(const std::string &host, int port, const std::string &username)
	{
		const std::wstring hostW(host.begin(), host.end());
		std::error_code ec;
		int sent = 0;

		for (fs::directory_iterator reports(g_reportsDir, ec), end; !ec && reports != end; reports.increment(ec))
		{
			const auto &report = *reports;
			std::error_code fileError;
			if (!report.is_directory(fileError) || fs::exists(report.path() / "sent.txt", fileError))
				continue;

			const std::string reportName = Utf8(report.path().filename());
			bool all = true;
			for (fs::directory_iterator files(report.path(), fileError); !fileError && files != end; files.increment(fileError))
			{
				const auto &file = *files;
				std::error_code sizeError;
				if (!file.is_regular_file(sizeError))
					continue;
				const std::string fileName = Utf8(file.path().filename());
				if (fs::file_size(file.path(), sizeError) > kMaxUploadBytes)
				{
					wo_native::DebugLog("crash report: " + reportName + "/" + fileName + " is too large to send; it stays on this PC");
					continue;
				}

				std::ifstream in(file.path(), std::ios::binary);
				std::vector<char> body((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
				const std::string query = "/crash?user=" + SafeName(username) + "&report=" + SafeName(reportName) + "&file=" + SafeName(fileName);
				std::string error;
				if (!PostFile(hostW, port, std::wstring(query.begin(), query.end()), body, error))
				{
					wo_native::DebugLog("crash report: sending " + reportName + "/" + fileName + " failed (" + error + "); trying again next session");
					all = false;
					break;
				}
			}

			if (all)
			{
				WriteText(report.path() / "sent.txt", "sent to " + host + ":" + std::to_string(port) + " on " + Timestamp() + "\r\n");
				++sent;
			}
		}

		if (sent > 0)
			wo_native::DebugLog("crash report: sent " + std::to_string(sent) + " report(s) to the host");
	}

	// a background thread in the game process: nothing may escape it
	static void UploadAll(std::string host, int port, std::string username)
	{
		try
		{
			UploadAllUnguarded(host, port, username);
		}
		catch (const std::exception &e)
		{
			wo_native::DebugLog(std::string("crash report: sending stopped: ") + e.what());
		}
		catch (...)
		{
			wo_native::DebugLog("crash report: sending stopped by an unknown error");
		}
		g_uploading.store(false);
	}

	void UploadPending(const std::string &host, int port, const std::string &username)
	{
		if (!g_installed.load() || port <= 0 || g_uploading.exchange(true))
			return;

		std::thread(UploadAll, host, port, username).detach();
	}

	bool IsUploading()
	{
		return g_uploading.load();
	}
} // namespace wo_crash
