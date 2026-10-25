import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.util.Base64;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.SocketException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.CodeSource;
import java.time.LocalTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicInteger;

public class WitcherServer
{
    private static final Map<String, PlayerSession> players = new ConcurrentHashMap<>();
    private static final Set<String> bannedIps = ConcurrentHashMap.newKeySet();
    private static final Set<String> whitelistedIps = ConcurrentHashMap.newKeySet();
    private static final Map<String, UsernameReservation> reservedUsernames = new ConcurrentHashMap<>();

    private static final AtomicBoolean running = new AtomicBoolean(true);
    private static final AtomicBoolean whitelistEnabled = new AtomicBoolean(false);

    private static final AtomicLong totalPacketsSent = new AtomicLong(0);
    private static final AtomicLong totalSendFailures = new AtomicLong(0);
    private static final AtomicLong totalBroadcastTicks = new AtomicLong(0);

    private static volatile long lastBroadcastTickNanos = 0L;

    private static final long PLAYER_TIMEOUT_NANOS = 5_000_000_000L;
    private static final long USERNAME_HOLD_NANOS = 60_000_000_000L;
    private static final long BROADCAST_HEARTBEAT_NANOS = 60_000_000_000L;
    // per player; channels are never released, so this must cover every channel one player's script uses
    private static final int MAX_COOP_CHANNELS = 8;
    private static final long COOP_REPEAT_NANOS = 100_000_000L;

    private static final int DEFAULT_PORT = 40000;
    private static final DateTimeFormatter LOG_TIME = DateTimeFormatter.ofPattern("HH:mm:ss");

    private static final int DEFAULT_STATUS_PORT = 40001;

    private static volatile HttpServer statusServer = null;
    private static volatile String cachedStatusFontBase64 = "";

    private static final String LAN_PROTOCOL = "1";
    private static final String MOD_VERSION = "0.3.0-dev";

    private static volatile int gamePort = DEFAULT_PORT;
    private static volatile int savePort = 0;
    private static volatile Path savesDir = null;

    private static final AtomicInteger nextPlayerId = new AtomicInteger(1);

    public static void main(String[] args) throws Exception
    {
        Properties serverProperties = loadServerProperties();
        String savesArg = null;
        List<String> positional = new ArrayList<>();
        for (int i = 0; i < args.length; i++)
        {
            if ("--saves".equals(args[i]) && i + 1 < args.length)
            {
                savesArg = args[++i];
            }
            else
            {
                positional.add(args[i]);
            }
        }
        args = positional.toArray(new String[0]);

        int port = choosePort(args, serverProperties);
        gamePort = port;
        whitelistEnabled.set(readBoolean(serverProperties, "whitelist", false));

        loadBannedIps();
        loadWhitelistIps();

        DatagramSocket socket = new DatagramSocket(port);

        boolean svgEnabled = readBoolean(serverProperties, "svgEnabled", false);
        int svgPort = DEFAULT_STATUS_PORT;

        if (svgEnabled)
        {
            svgPort = chooseSvgPort(serverProperties);
            loadStatusAssets();
            statusServer = startStatusServer(svgPort);
        }

        if (savesArg != null && Files.isDirectory(Paths.get(savesArg)))
        {
            savesDir = Paths.get(savesArg);
            savePort = port + 1;
            HttpServer saveServer = (statusServer != null && svgPort == savePort)
                    ? statusServer
                    : HttpServer.create(new InetSocketAddress(savePort), 0);
            saveServer.createContext("/save", WitcherServer::handleSaveDownload);
            saveServer.createContext("/save/name", WitcherServer::handleSaveName);
            if (saveServer != statusServer)
            {
                saveServer.setExecutor(null);
                saveServer.start();
            }
        }
        else if (savesArg != null)
        {
            dbg("Save folder not found, the other player won't get your save: %s\n", savesArg);
        }

        dbgNotime("Launching Witcher Online for The Witcher 3: Wild Hunt...\n");
        dbgNotime("Author: rejuvenate7 - Github: https://github.com/rejuvenate7\n");
        dbg("Starting Witcher Online server on *:%d\n", port);

        if (svgEnabled)
        {
            dbg("Starting Witcher Online status SVG server on *:%d\n", svgPort);
            dbg("Status SVG: http://127.0.0.1:%d/status.svg\n", svgPort);
        }

        if (savesDir != null)
        {
            dbg("Sharing your newest save with the other player on TCP %d (home network only): %s\n", savePort, savesDir);
        }

        dbg("For help, type \"help\" or \"?\"\n");

        Thread recvThread = startThread("udp-recv", () -> receiveLoop(socket));
        Thread sendThread = startThread("udp-broadcast", () -> broadcastLoop(socket));
        Thread cleanupThread = startThread("udp-cleanup", WitcherServer::cleanupLoop);
        Thread consoleThread = startThread("console", () -> consoleLoop(socket));

        recvThread.join();
        sendThread.join();
        cleanupThread.join();
        consoleThread.join();
    }

    private static int chooseSvgPort(Properties properties)
    {
        String propertyPort = properties.getProperty("svgPort");

        if (propertyPort != null)
        {
            Integer parsed = parsePort(propertyPort.trim());

            if (parsed != null)
            {
                return parsed;
            }

            System.err.println("Invalid server.properties svgPort: " + propertyPort + " (falling back)");
        }

        return DEFAULT_STATUS_PORT;
    }

    private static HttpServer startStatusServer(int statusPort) throws IOException
    {
        HttpServer server = HttpServer.create(new InetSocketAddress(statusPort), 0);

        server.createContext("/status.svg", WitcherServer::handleStatusSvg);
        server.createContext("/players.svg", WitcherServer::handleStatusSvg);
        server.createContext("/status.json", WitcherServer::handleStatusJson);

        server.setExecutor(null);
        server.start();

        return server;
    }

    private static boolean isHomeNetwork(java.net.InetAddress address)
    {
        return address.isLoopbackAddress() || address.isSiteLocalAddress() || address.isLinkLocalAddress();
    }

    private static Path newestSave() throws IOException
    {
        try (java.util.stream.Stream<Path> files = Files.list(savesDir))
        {
            return files
                    .filter(p -> p.getFileName().toString().toLowerCase(Locale.ROOT).endsWith(".sav"))
                    .max(java.util.Comparator.comparingLong(p -> p.toFile().lastModified()))
                    .orElse(null);
        }
    }

    // Name of the newest save only, so the join launcher can poll for new saves cheaply.
    private static void handleSaveName(HttpExchange exchange) throws IOException
    {
        if (!isHomeNetwork(exchange.getRemoteAddress().getAddress()))
        {
            sendHttp(exchange, 403, "text/plain; charset=utf-8", "home network only");
            return;
        }

        Path newest = newestSave();
        String name = newest == null ? "" : newest.getFileName().toString().replaceAll("(?i)\\.sav$", "");
        sendHttp(exchange, newest == null ? 404 : 200, "text/plain; charset=utf-8", name);
    }

    // Zip of the host's newest save (.sav plus its .png/.json), for the joining player's co-op slot.
    private static void handleSaveDownload(HttpExchange exchange) throws IOException
    {
        if (!isHomeNetwork(exchange.getRemoteAddress().getAddress()))
        {
            sendHttp(exchange, 403, "text/plain; charset=utf-8", "home network only");
            return;
        }

        if (!"GET".equals(exchange.getRequestMethod()))
        {
            sendHttp(exchange, 405, "text/plain; charset=utf-8", "GET only");
            return;
        }

        Path newest = newestSave();

        if (newest == null)
        {
            sendHttp(exchange, 404, "text/plain; charset=utf-8", "no save yet");
            return;
        }

        String fileName = newest.getFileName().toString();
        String base = fileName.substring(0, fileName.length() - 4);

        java.io.ByteArrayOutputStream buffer = new java.io.ByteArrayOutputStream();
        try (java.util.zip.ZipOutputStream zip = new java.util.zip.ZipOutputStream(buffer))
        {
            for (String ext : new String[] { ".sav", ".png", ".json" })
            {
                Path part = savesDir.resolve(base + ext);
                if (!Files.isRegularFile(part))
                {
                    continue;
                }
                zip.putNextEntry(new java.util.zip.ZipEntry(base + ext));
                zip.write(Files.readAllBytes(part));
                zip.closeEntry();
            }
        }

        byte[] body = buffer.toByteArray();
        exchange.getResponseHeaders().set("Content-Type", "application/zip");
        exchange.getResponseHeaders().set("X-Save-Name", base);
        exchange.sendResponseHeaders(200, body.length);
        try (OutputStream out = exchange.getResponseBody())
        {
            out.write(body);
        }

        dbg("Sent save %s to %s\n", base, exchange.getRemoteAddress().getAddress().getHostAddress());
    }

    private static void handleStatusSvg(HttpExchange exchange) throws IOException
    {
        String svg = buildStatusSvg();

        sendHttp(exchange, 200, "image/svg+xml; charset=utf-8", svg);
    }

    private static void handleStatusJson(HttpExchange exchange) throws IOException
    {
        List<String> names = getConnectedPlayerNames();

        StringBuilder json = new StringBuilder();

        json.append("{");
        json.append("\"server\":\"Witcher Online\",");
        json.append("\"online\":").append(names.size()).append(",");
        json.append("\"players\":[");

        for (int i = 0; i < names.size(); i++)
        {
            if (i > 0)
            {
                json.append(",");
            }

            json.append("\"").append(jsonEscape(names.get(i))).append("\"");
        }

        json.append("]");
        json.append("}");

        sendHttp(exchange, 200, "application/json; charset=utf-8", json.toString());
    }

    private static void loadStatusAssets()
    {
        Path dir = statusAssetsDir();

        dbg("Status assets dir=%s\n", dir);

        cachedStatusFontBase64 = readBase64IfExists(dir.resolve("status-font.woff2"));

        dbg("Loaded status font from %s\n", dir);
    }

    private static Path statusAssetsDir()
    {
        return appDir().resolve("assets").resolve("status");
    }

    private static String readBase64IfExists(Path path)
    {
        try
        {
            if (!Files.exists(path))
            {
                return "";
            }

            byte[] data = Files.readAllBytes(path);
            return Base64.getEncoder().encodeToString(data);
        }
        catch (Exception e)
        {
            dbg("Failed to load status asset %s: %s\n", path, e.getMessage());
            return "";
        }
    }

    private static int estimateSvgTextWidth(String text, int fontSize)
    {
        if (text == null || text.isEmpty())
        {
            return fontSize;
        }

        double width = 0.0;

        for (int i = 0; i < text.length(); i++)
        {
            char c = text.charAt(i);

            if (c == ' ')
            {
                width += fontSize * 0.28;
            }
            else if (c == 'i' || c == 'l' || c == 'I' || c == '!' || c == '.' || c == ',' || c == '\'')
            {
                width += fontSize * 0.28;
            }
            else if (c == 'W' || c == 'M')
            {
                width += fontSize * 0.82;
            }
            else if (c >= '0' && c <= '9')
            {
                width += fontSize * 0.48;
            }
            else
            {
                width += fontSize * 0.58;
            }
        }

        width += text.length();

        return (int) Math.ceil(width) + 4;
    }

    private static String buildStatusSvg()
    {
        List<String> names = getConnectedPlayerNames();
        int count = names.size();

        String titleText = "Witcher Online";
        String playerCountText = count == 1 ? "1 player online" : count + " players online";

        StringBuilder svg = new StringBuilder();

        int paddingX = 4;
        int paddingTop = 4;
        int paddingBottom = 6;

        int titleFontSize = 58;
        int countFontSize = 32;

        int titleWidth = estimateSvgTextWidth(titleText, titleFontSize);
        int countWidth = estimateSvgTextWidth(playerCountText, countFontSize);

        int svgW = Math.max(titleWidth, countWidth) + paddingX * 2;

        int titleY = paddingTop + 54;
        int countY = titleY + 39;

        int svgH = countY + paddingBottom + 5;

        int textX = paddingX;

        svg.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"");
        svg.append(svgW);
        svg.append("\" height=\"");
        svg.append(svgH);
        svg.append("\" viewBox=\"0 0 ");
        svg.append(svgW);
        svg.append(" ");
        svg.append(svgH);
        svg.append("\">");

        svg.append("<defs>");
        svg.append("<style>");

        if (!cachedStatusFontBase64.isEmpty())
        {
            svg.append("@font-face{");
            svg.append("font-family:'WitcherStatusFont';");
            svg.append("src:url('data:font/woff2;base64,");
            svg.append(cachedStatusFontBase64);
            svg.append("') format('woff2');");
            svg.append("font-weight:normal;");
            svg.append("font-style:normal;");
            svg.append("}");
        }

        svg.append(".text-outline{");
        svg.append("font-family:'WitcherStatusFont',Georgia,serif;");
        svg.append("stroke:#000000;");
        svg.append("stroke-width:2px;");
        svg.append("stroke-opacity:1;");
        svg.append("stroke-linejoin:round;");
        svg.append("paint-order:stroke fill;");
        svg.append("}");

        svg.append(".title-text{");
        svg.append("font-size:");
        svg.append(titleFontSize);
        svg.append("px;");
        svg.append("fill:#ffffff;");
        svg.append("letter-spacing:1px;");
        svg.append("}");

        svg.append(".count-text{");
        svg.append("font-size:");
        svg.append(countFontSize);
        svg.append("px;");
        svg.append("fill:#f7ead0;");
        svg.append("letter-spacing:1px;");
        svg.append("}");

        svg.append("</style>");
        svg.append("</defs>");

        svg.append("<text class=\"text-outline title-text\" x=\"");
        svg.append(textX);
        svg.append("\" y=\"");
        svg.append(titleY);
        svg.append("\">");
        svg.append(xmlEscape(titleText));
        svg.append("</text>");

        svg.append("<text class=\"text-outline count-text\" x=\"");
        svg.append(textX);
        svg.append("\" y=\"");
        svg.append(countY);
        svg.append("\">");
        svg.append(xmlEscape(playerCountText));
        svg.append("</text>");

        svg.append("</svg>");

        return svg.toString();
    }

    private static List<String> getConnectedPlayerNames()
    {
        List<String> names = new ArrayList<>();

        for (PlayerSession session : players.values())
        {
            if (session != null && session.username != null && !session.username.trim().isEmpty())
            {
                names.add(session.username.trim());
            }
        }

        Collections.sort(names, String.CASE_INSENSITIVE_ORDER);

        return names;
    }

    private static void sendHttp(HttpExchange exchange, int status, String contentType, String body) throws IOException
    {
        byte[] data = body.getBytes(StandardCharsets.UTF_8);

        Headers headers = exchange.getResponseHeaders();
        headers.set("Content-Type", contentType);
        headers.set("Cache-Control", "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0, s-maxage=0");
        headers.set("Pragma", "no-cache");
        headers.set("Expires", "0");
        headers.set("Access-Control-Allow-Origin", "*");

        exchange.sendResponseHeaders(status, data.length);

        try (OutputStream os = exchange.getResponseBody())
        {
            os.write(data);
        }
    }

    private static String xmlEscape(String s)
    {
        if (s == null)
        {
            return "";
        }

        StringBuilder out = new StringBuilder(s.length() + 8);

        for (int i = 0; i < s.length(); i++)
        {
            char c = s.charAt(i);

            if (c == '&')
            {
                out.append("&amp;");
            }
            else if (c == '<')
            {
                out.append("&lt;");
            }
            else if (c == '>')
            {
                out.append("&gt;");
            }
            else if (c == '"')
            {
                out.append("&quot;");
            }
            else if (c == '\'')
            {
                out.append("&apos;");
            }
            else
            {
                out.append(c);
            }
        }

        return out.toString();
    }

    private static Thread startThread(String name, Runnable target)
    {
        Thread thread = new Thread(target, name);
        thread.setUncaughtExceptionHandler((t, e) ->
        {
            dbg("Thread %s crashed: %s\n", t.getName(), e.toString());
            e.printStackTrace();
        });
        thread.start();
        return thread;
    }

    private static void receiveLoop(DatagramSocket socket)
    {
        byte[] buffer = new byte[8192];

        while (running.get())
        {
            try
            {
                DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
                socket.receive(packet);

                ClientEndpoint sender = new ClientEndpoint(packet.getAddress(), packet.getPort());
                String senderIp = normalizeIp(sender.address.getHostAddress());

                String msg = new String(
                        packet.getData(),
                        packet.getOffset(),
                        packet.getLength(),
                        StandardCharsets.UTF_8
                );

                if (isIpBanned(senderIp))
                {
                    safeSend(socket, sender, "ERROR\tBANNED");
                    continue;
                }

                if (whitelistEnabled.get() && !isIpWhitelisted(senderIp))
                {
                    safeSend(socket, sender, "ERROR\tNOT_WHITELISTED");
                    continue;
                }

                handleMessage(socket, sender, msg);
            }
            catch (SocketException e)
            {
                if (running.get())
                {
                    e.printStackTrace();
                }
                break;
            }
            catch (Exception e)
            {
                e.printStackTrace();
            }
        }
    }

    private static boolean isUpdateOpcode(String opcode)
    {
        return "MOVE".equals(opcode)
                || "UPDATE1A".equals(opcode)
                || "UPDATE1B".equals(opcode)
                || "UPDATE2A".equals(opcode)
                || "UPDATE2B".equals(opcode)
                || "UPDATE3".equals(opcode)
                || "UPDATE4".equals(opcode)
                || "COOP".equals(opcode);
    }

    private static boolean isInteger(String value)
    {
        if (value == null || value.isEmpty())
        {
            return false;
        }

        for (int i = 0; i < value.length(); i++)
        {
            char c = value.charAt(i);

            if (i == 0 && c == '-')
            {
                continue;
            }

            if (c < '0' || c > '9')
            {
                return false;
            }
        }

        return true;
    }

    private static void handleMessage(DatagramSocket socket, ClientEndpoint sender, String msg) throws Exception
    {
        String[] parts = msg.split("\t", -1);

        if (parts.length < 2)
        {
            return;
        }

        String opcode = parts[0];

        if ("DISCOVER".equals(opcode) && "W3COOP".equals(parts[1]))
        {
            safeSend(socket, sender, "W3COOP_HOST\t" + LAN_PROTOCOL + "\t" + MOD_VERSION + "\t" + gamePort + "\t" + savePort);
            return;
        }

        if (!isUpdateOpcode(opcode))
        {
            return;
        }

        int packetPlayerId = 0;
        String username;
        int fieldsStart;

        if (parts.length >= 3 && isInteger(parts[1].trim()))
        {
            try
            {
                packetPlayerId = Integer.parseInt(parts[1].trim());
            }
            catch (NumberFormatException e)
            {
                packetPlayerId = 0;
            }

            username = unescapeField(parts[2]).trim();
            fieldsStart = 3;
        }
        else
        {
            username = unescapeField(parts[1]).trim();
            fieldsStart = 2;
        }

        if (username.isEmpty())
        {
            safeSend(socket, sender, "ERROR\tINVALID_USERNAME");
            return;
        }

        String usernameKey = normalizeUsernameKey(username);
        String senderIp = normalizeIp(sender.address.getHostAddress());
        long now = System.nanoTime();

        PlayerSession current = players.get(usernameKey);

        if (current != null)
        {
            String currentIp = normalizeIp(current.endpoint.address.getHostAddress());

            boolean sameEndpoint = current.endpoint.equals(sender);
            boolean sameIp = currentIp.equals(senderIp);
            boolean expired = (now - current.lastSeen) > PLAYER_TIMEOUT_NANOS;

            if (sameEndpoint)
            {
                // normal packet from same endpoint
            }
            else if (sameIp)
            {
                ClientEndpoint old = current.endpoint;
                current.endpoint = sender;
                dbg("Updated endpoint for %s from %s to %s\n", username, old, sender);
            }
            else if (expired && isHomeNetwork(sender.address))
            {
                // a home-network player whose address changed (Wi-Fi reconnect, DHCP) takes their name back
                players.remove(usernameKey, current);
                reservedUsernames.remove(usernameKey);
                dbg("%s reconnected from new address %s\n", username, sender);
            }
            else if (expired)
            {
                boolean reserved = reserveTimedOutPlayer(usernameKey, current, now);

                if (reserved)
                {
                    dbg("Rejected %s from %s because username is reserved for previous IP\n", username, sender);
                    safeSend(socket, sender, "ERROR\tUSERNAME_TAKEN");
                    return;
                }

                current = players.get(usernameKey);

                if (current != null)
                {
                    dbg("Rejected duplicate username %s from %s because owned by %s\n",
                            username, sender, current.endpoint);
                    safeSend(socket, sender, "ERROR\tUSERNAME_TAKEN");
                    return;
                }
            }
            else
            {
                dbg("Rejected duplicate username %s from %s because owned by %s\n",
                        username, sender, current.endpoint);
                safeSend(socket, sender, "ERROR\tUSERNAME_TAKEN");
                return;
            }
        }

        if (!players.containsKey(usernameKey))
        {
            UsernameReservation reservation = reservedUsernames.get(usernameKey);

            if (reservation != null && now >= reservation.expiresAt)
            {
                reservedUsernames.remove(usernameKey, reservation);
                reservation = null;
            }

            if (reservation != null)
            {
                if (!reservation.ip.equals(senderIp) && !isHomeNetwork(sender.address))
                {
                    dbg("Rejected username %s from %s because it is reserved for IP %s\n",
                            username, sender, reservation.ip);
                    safeSend(socket, sender, "ERROR\tUSERNAME_TAKEN");
                    return;
                }

                reservedUsernames.remove(usernameKey, reservation);
                dbg("Restored reserved username %s for %s\n", username, sender);
            }

            int playerIdToUse;

            if (packetPlayerId > 0)
            {
                PlayerSession idOwner = findPlayerById(packetPlayerId);

                if (idOwner != null && !normalizeUsernameKey(idOwner.username).equals(usernameKey))
                {
                    dbg("Rejected username %s from %s because requested id=%d is already owned by %s\n",
                            username,
                            sender,
                            packetPlayerId,
                            idOwner.username);

                    safeSend(socket, sender, "ERROR\tID_TAKEN");
                    return;
                }

                playerIdToUse = packetPlayerId;
                bumpNextPlayerIdPast(playerIdToUse);
            }
            else
            {
                playerIdToUse = allocateNewPlayerId();
            }

            PlayerSession created = new PlayerSession(playerIdToUse, username, sender, now);
            PlayerSession race = players.putIfAbsent(usernameKey, created);

            if (race == null)
            {
                current = created;
                dbg("Accepted username %s id=%d for %s\n", username, created.playerId, sender);
            }
            else
            {
                current = race;

                String currentIp = normalizeIp(current.endpoint.address.getHostAddress());

                if (!currentIp.equals(senderIp) && !current.endpoint.equals(sender))
                {
                    dbg("Rejected duplicate username %s from %s because owned by %s\n",
                            username, sender, current.endpoint);
                    safeSend(socket, sender, "ERROR\tUSERNAME_TAKEN");
                    return;
                }

                current.endpoint = sender;
            }
        }

        current.lastSeen = now;

        List<String> fields = new ArrayList<>();

        for (int i = fieldsStart; i < parts.length; i++)
        {
            fields.add(unescapeField(parts[i]));
        }

        List<String> frozenFields = Collections.unmodifiableList(fields);

        if ("MOVE".equals(opcode))
        {
            if (frozenFields.size() < 8)
            {
                return;
            }

            int sent = broadcastChunk(socket, snapshotRecipients(), current, "MOVE", frozenFields);
            totalPacketsSent.addAndGet(sent);
            return;
        }

        if ("COOP".equals(opcode))
        {
            String channel = frozenFields.isEmpty() ? "" : frozenFields.get(0);

            if (!channel.isEmpty() && channel.length() <= 8
                    && (current.coopFields.containsKey(channel) || current.coopFields.size() < MAX_COOP_CHANNELS))
            {
                current.coopFields.put(channel, frozenFields);
                // forwarded at once: a monster's attack shouldn't wait up to a broadcast tick (100 ms) to reach members
                int sent = broadcastChunk(socket, snapshotRecipients(), current, "COOP", frozenFields);
                totalPacketsSent.addAndGet(sent);
                current.coopForwardedAt.put(channel, System.nanoTime());
            }
            return;
        }

        if ("UPDATE1A".equals(opcode))
        {
            current.update1AFields = frozenFields;
        }
        else if ("UPDATE1B".equals(opcode))
        {
            current.update1BFields = frozenFields;
        }
        else if ("UPDATE2A".equals(opcode))
        {
            current.update2AFields = frozenFields;
        }
        else if ("UPDATE2B".equals(opcode))
        {
            current.update2BFields = frozenFields;
        }
        else if ("UPDATE3".equals(opcode))
        {
            current.update3Fields = frozenFields;
        }
        else if ("UPDATE4".equals(opcode))
        {
            current.update4Fields = frozenFields;
        }
    }

    private static void cleanupLoop()
    {
        while (running.get())
        {
            try
            {
                long now = System.nanoTime();

                for (Map.Entry<String, PlayerSession> entry : players.entrySet())
                {
                    PlayerSession session = entry.getValue();
                    if ((now - session.lastSeen) > PLAYER_TIMEOUT_NANOS)
                    {
                        reserveTimedOutPlayer(entry.getKey(), session, now);
                    }
                }

                for (Map.Entry<String, UsernameReservation> entry : reservedUsernames.entrySet())
                {
                    UsernameReservation reservation = entry.getValue();
                    if (now >= reservation.expiresAt)
                    {
                        if (reservedUsernames.remove(entry.getKey(), reservation))
                        {
                            dbg("Released reserved username %s for IP %s\n",
                                    reservation.username,
                                    reservation.ip);
                        }
                    }
                }

                Thread.sleep(1000);
            }
            catch (InterruptedException e)
            {
                Thread.currentThread().interrupt();
                break;
            }
            catch (Exception e)
            {
                e.printStackTrace();
            }
        }
    }

    private static void broadcastLoop(DatagramSocket socket)
    {
        long lastHeartbeat = System.nanoTime();

        while (running.get())
        {
            try
            {
                List<ClientEndpoint> recipients = snapshotRecipients();
                int packetsSentThisTick = 0;

                for (PlayerSession session : players.values())
                {
                    packetsSentThisTick += broadcastChunk(socket, recipients, session, "UPDATE1A", session.update1AFields);
                    packetsSentThisTick += broadcastChunk(socket, recipients, session, "UPDATE1B", session.update1BFields);
                    packetsSentThisTick += broadcastChunk(socket, recipients, session, "UPDATE2A", session.update2AFields);
                    packetsSentThisTick += broadcastChunk(socket, recipients, session, "UPDATE2B", session.update2BFields);
                    packetsSentThisTick += broadcastChunk(socket, recipients, session, "UPDATE3", session.update3Fields);
                    packetsSentThisTick += broadcastChunk(socket, recipients, session, "UPDATE4", session.update4Fields);

                    for (Map.Entry<String, List<String>> coop : session.coopFields.entrySet())
                    {
                        // repeated (for lost packets) only if nothing newer went out on arrival lately
                        Long forwarded = session.coopForwardedAt.get(coop.getKey());
                        if (forwarded != null && System.nanoTime() - forwarded < COOP_REPEAT_NANOS)
                        {
                            continue;
                        }
                        packetsSentThisTick += broadcastChunk(socket, recipients, session, "COOP", coop.getValue());
                    }
                }

                totalPacketsSent.addAndGet(packetsSentThisTick);
                totalBroadcastTicks.incrementAndGet();
                lastBroadcastTickNanos = System.nanoTime();

                long now = System.nanoTime();
                if ((now - lastHeartbeat) >= BROADCAST_HEARTBEAT_NANOS)
                {
                    dbg("Broadcast heartbeat: players=%d recipients=%d packetsSent=%d totalPacketsSent=%d totalSendFailures=%d\n",
                            players.size(),
                            recipients.size(),
                            packetsSentThisTick,
                            totalPacketsSent.get(),
                            totalSendFailures.get());
                    lastHeartbeat = now;
                }

                Thread.sleep(100);
            }
            catch (InterruptedException e)
            {
                Thread.currentThread().interrupt();
                break;
            }
            catch (Exception e)
            {
                e.printStackTrace();
            }
        }
    }

    private static List<ClientEndpoint> snapshotRecipients()
    {
        Set<ClientEndpoint> unique = new HashSet<>();
        for (PlayerSession session : players.values())
        {
            unique.add(session.endpoint);
        }
        return new ArrayList<>(unique);
    }

    private static int broadcastChunk(
            DatagramSocket socket,
            List<ClientEndpoint> recipients,
            PlayerSession session,
            String opcode,
            List<String> fields)
    {
        if (fields == null || fields.isEmpty())
        {
            return 0;
        }

        String packetText = buildTypedPacket(opcode, session.playerId, session.username, fields);
        byte[] data = packetText.getBytes(StandardCharsets.UTF_8);

        // enemy snapshots are routinely larger; logging them every tick would flood the console
        if (data.length > 1200 && !"COOP".equals(opcode))
        {
            dbg("Large packet: opcode=%s user=%s bytes=%d\n data=%s", opcode, session.username, data.length, packetText);
        }

        int sent = 0;

        for (ClientEndpoint client : recipients)
        {
            try
            {
                DatagramPacket packet = new DatagramPacket(
                        data,
                        data.length,
                        client.address,
                        client.port
                );
                socket.send(packet);
                sent++;
            }
            catch (Exception e)
            {
                totalSendFailures.incrementAndGet();
                dbg("Broadcast send failed to %s for %s/%s: %s\n",
                        client, session.username, opcode, e.toString());
            }
        }

        return sent;
    }

    private static String buildTypedPacket(String opcode, int playerId, String username, List<String> fields)
    {
        StringBuilder sb = new StringBuilder();

        sb.append(opcode)
                .append("\t")
                .append(playerId)
                .append("\t")
                .append(escapeField(username));

        for (String field : fields)
        {
            sb.append("\t").append(escapeField(field));
        }

        return sb.toString();
    }

    private static void consoleLoop(DatagramSocket socket)
    {
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8)))
        {
            String line;
            while (running.get() && (line = reader.readLine()) != null)
            {
                handleConsoleCommand(socket, line.trim());
            }
        }
        catch (IOException e)
        {
            if (running.get())
            {
                e.printStackTrace();
            }
        }
    }

    private static void handleConsoleCommand(DatagramSocket socket, String line)
    {
        if (line.isEmpty())
        {
            return;
        }

        if (line.equals("list"))
        {
            dbg("---- Connected players (%d) ----\n", players.size());
            long now = System.nanoTime();

            for (PlayerSession session : players.values())
            {
                long secsSinceSeen = Math.max(0L, (now - session.lastSeen) / 1_000_000_000L);

                String locationRaw = getLocation(session.update1AFields);
                String region = getRegion(locationRaw);

                List<String> coords = getCoords(session.update1AFields);
                String coordsStr = "?";
                if (coords.size() == 3)
                {
                    coordsStr = "(" + coords.get(0) + ", " + coords.get(1) + ", " + coords.get(2) + ")";
                }

                dbg("name=\"%s\"  ip=%s  location=%s  coords=%s  lastSeen=%ds ago\n",
                        session.username,
                        session.endpoint,
                        locationRaw.isEmpty() ? "?" : region,
                        coordsStr,
                        secsSinceSeen);
            }

            dbgNotime("\n");
            return;
        }

        if (line.equals("stats"))
        {
            long now = System.nanoTime();
            long lastTickAgeMs = (lastBroadcastTickNanos == 0L)
                    ? -1L
                    : Math.max(0L, (now - lastBroadcastTickNanos) / 1_000_000L);

            dbg("---- Server stats ----\n");
            dbg("players=%d\n", players.size());
            dbg("reservedUsernames=%d\n", reservedUsernames.size());
            dbg("broadcastTicks=%d\n", totalBroadcastTicks.get());
            dbg("totalPacketsSent=%d\n", totalPacketsSent.get());
            dbg("totalSendFailures=%d\n", totalSendFailures.get());
            dbg("lastBroadcastTickAgeMs=%d\n\n", lastTickAgeMs);
            return;
        }

        if (line.startsWith("kick"))
        {
            String arg = trimCommandArg(line, "kick");
            if (arg.isEmpty())
            {
                dbg("Usage: kick <name|ip>\n\n");
                return;
            }

            PlayerSession victim = findPlayer(arg);
            if (victim == null)
            {
                dbg("No connected player matches \"%s\".\n\n", arg);
                return;
            }

            dbg("Kicking %s (%s)\n", victim.username, victim.endpoint);
            kickPlayer(socket, victim, "KICK\tKicked by server");
            dbgNotime("\n");
            return;
        }

        if (line.startsWith("ban"))
        {
            String arg = trimCommandArg(line, "ban");
            if (arg.isEmpty())
            {
                dbg("Usage: ban <name|ip>\n\n");
                return;
            }

            PlayerSession victim = findPlayer(arg);
            String ipToBan = (victim != null)
                    ? normalizeIp(victim.endpoint.address.getHostAddress())
                    : normalizeIp(stripPort(arg));

            if (ipToBan.isEmpty())
            {
                dbg("Could not resolve \"%s\" to an IP address to ban.\n\n", arg);
                return;
            }

            boolean newlyBanned = bannedIps.add(ipToBan);
            if (newlyBanned)
            {
                saveBannedIps();
                dbg("Added IP '%s' to ban list.\n", ipToBan);
            }
            else
            {
                dbg("IP '%s' is already in ban list.\n", ipToBan);
            }

            if (victim != null)
            {
                kickAllPlayersByIp(socket, ipToBan, "KICK\tBanned by server");
            }

            dbgNotime("\n");
            return;
        }

        if (line.startsWith("unban"))
        {
            String arg = trimCommandArg(line, "unban");
            if (arg.isEmpty())
            {
                dbg("Usage: unban <ip>\n\n");
                return;
            }

            String ip = normalizeIp(stripPort(arg));
            if (ip.isEmpty())
            {
                dbg("Usage: unban <ip>\n\n");
                return;
            }

            if (bannedIps.remove(ip))
            {
                saveBannedIps();
                dbg("'%s' has been unbanned.\n\n", ip);
            }
            else
            {
                dbg("IP '%s' is not banned.\n\n", ip);
            }
            return;
        }

        if (line.startsWith("whitelist"))
        {
            String arg = trimCommandArg(line, "whitelist");
            if (arg.isEmpty())
            {
                dbg("Usage: whitelist on|off - enable or disable the whitelist\n");
                dbg("Usage: whitelist <ip>|remove <ip> - add or remove IP to whitelist\n\n");
                return;
            }

            String lower = arg.toLowerCase(Locale.ROOT);
            if (lower.equals("on"))
            {
                whitelistEnabled.set(true);
                dbg("The whitelist is now enabled.\n\n");
                return;
            }

            if (lower.equals("off"))
            {
                whitelistEnabled.set(false);
                dbg("The whitelist is now disabled.\n\n");
                return;
            }

            if (lower.startsWith("remove"))
            {
                String ip = normalizeIp(stripPort(trimCommandArg(arg, "remove")));
                if (ip.isEmpty())
                {
                    dbg("Usage: whitelist remove <ip>\n\n");
                    return;
                }

                if (whitelistedIps.remove(ip))
                {
                    saveWhitelistIps();
                    dbg("Removed IP '%s' from whitelist.\n\n", ip);
                }
                else
                {
                    dbg("IP '%s' is not in the whitelist.\n\n", ip);
                }
                return;
            }

            String ip = normalizeIp(stripPort(arg));
            if (ip.isEmpty())
            {
                dbg("Usage: whitelist on|off - enable or disable the whitelist\n");
                dbg("Usage: whitelist <ip>|remove <ip> - add or remove IP to whitelist\n\n");
                return;
            }

            if (whitelistedIps.add(ip))
            {
                saveWhitelistIps();
                dbg("Added IP '%s' to whitelist.\n\n", ip);
            }
            else
            {
                dbg("IP '%s' is already in whitelist.\n\n");
            }
            return;
        }

        if (line.equals("stop"))
        {
            dbg("Shutting down...\n\n");
            shutdown(socket);
            return;
        }

        if (line.equals("help") || line.equals("?"))
        {
            dbg("--------- Help: Index ---------\n");
            dbg("kick <name|ip>            - remove a player and send a kick notice\n");
            dbg("ban <name|ip>             - ban by name/ip and prevent future updates\n");
            dbg("unban <ip>                - remove IP from ban list\n");
            dbg("whitelist on|off|<ip>     - toggle whitelist or add IP to whitelist\n");
            dbg("whitelist remove <ip>     - remove IP from whitelist\n");
            dbg("list                      - list connected players\n");
            dbg("stats                     - show broadcast/server health counters\n");
            dbg("about                     - info about Witcher Online\n");
            dbg("stop                      - stop server\n");
            dbg("help                      - show this help\n\n");
            return;
        }

        if (line.equals("about"))
        {
            dbg("--------- About ---------\n");
            dbg("Witcher Online v2.0\n");
            dbg("by rejuvenate7\n");
            dbg("https://github.com/rejuvenate7\n");
            dbg("https://discord.gg/KYu9c5TWej\n\n");
            return;
        }

        dbg("Unknown command: %s (type 'help')\n\n", line);
    }

    private static void kickPlayer(DatagramSocket socket, PlayerSession victim, String kickText)
    {
        String usernameKey = normalizeUsernameKey(victim.username);

        PlayerSession removed = players.remove(usernameKey);
        reservedUsernames.remove(usernameKey);

        if (removed != null)
        {
            safeSend(socket, removed.endpoint, kickText);
        }
    }

    private static void kickAllPlayersByIp(DatagramSocket socket, String ip, String kickText)
    {
        List<PlayerSession> victims = new ArrayList<>();
        for (PlayerSession session : players.values())
        {
            String sessionIp = normalizeIp(session.endpoint.address.getHostAddress());
            if (sessionIp.equals(ip))
            {
                victims.add(session);
            }
        }

        for (PlayerSession victim : victims)
        {
            dbg("Removing %s (%s) after ban\n", victim.username, victim.endpoint);
            kickPlayer(socket, victim, kickText);
        }
    }

    private static PlayerSession findPlayer(String arg)
    {
        PlayerSession exact = players.get(normalizeUsernameKey(arg));
        if (exact != null)
        {
            return exact;
        }

        String ipArg = normalizeIp(stripPort(arg));

        for (PlayerSession session : players.values())
        {
            String sessionIp = normalizeIp(session.endpoint.address.getHostAddress());
            if (!ipArg.isEmpty() && sessionIp.equals(ipArg))
            {
                return session;
            }
        }

        return null;
    }

    private static void shutdown(DatagramSocket socket)
    {
        if (!running.compareAndSet(true, false))
        {
            return;
        }

        socket.close();

        HttpServer server = statusServer;
        if (server != null)
        {
            server.stop(0);
            statusServer = null;
        }
    }

    private static void sendText(DatagramSocket socket, ClientEndpoint client, String text) throws Exception
    {
        byte[] data = text.getBytes(StandardCharsets.UTF_8);
        DatagramPacket packet = new DatagramPacket(data, data.length, client.address, client.port);
        socket.send(packet);
    }

    private static void safeSend(DatagramSocket socket, ClientEndpoint client, String text)
    {
        try
        {
            sendText(socket, client, text);
        }
        catch (Exception e)
        {
            if (running.get())
            {
                e.printStackTrace();
            }
        }
    }

    private static boolean isIpBanned(String ip)
    {
        return bannedIps.contains(normalizeIp(ip));
    }

    private static boolean isIpWhitelisted(String ip)
    {
        return whitelistedIps.contains(normalizeIp(ip));
    }

    private static void loadBannedIps()
    {
        Set<String> loaded = loadJsonStringArray(bannedPlayersPath());
        bannedIps.clear();
        bannedIps.addAll(loaded);
        if (!loaded.isEmpty())
        {
            dbg("Loaded %d banned IP(s) from %s\n", loaded.size(), bannedPlayersPath());
        }
    }

    private static void saveBannedIps()
    {
        saveJsonStringArray(bannedPlayersPath(), bannedIps, "banned IP list");
    }

    private static void loadWhitelistIps()
    {
        Set<String> loaded = loadJsonStringArray(whitelistedPlayersPath());
        whitelistedIps.clear();
        whitelistedIps.addAll(loaded);
        if (!loaded.isEmpty())
        {
            dbg("Loaded %d whitelisted IP(s) from %s\n", loaded.size(), whitelistedPlayersPath());
        }
    }

    private static void saveWhitelistIps()
    {
        saveJsonStringArray(whitelistedPlayersPath(), whitelistedIps, "whitelist IP list");
    }

    private static Set<String> loadJsonStringArray(Path path)
    {
        Set<String> out = new HashSet<>();

        if (!Files.exists(path))
        {
            return out;
        }

        try
        {
            String content = Files.readString(path, StandardCharsets.UTF_8);
            StringBuilder cur = new StringBuilder();
            boolean inString = false;
            boolean escaping = false;

            for (int i = 0; i < content.length(); i++)
            {
                char c = content.charAt(i);

                if (!inString)
                {
                    if (c == '"')
                    {
                        inString = true;
                        cur.setLength(0);
                    }
                    continue;
                }

                if (escaping)
                {
                    cur.append(c);
                    escaping = false;
                    continue;
                }

                if (c == '\\')
                {
                    escaping = true;
                    continue;
                }

                if (c == '"')
                {
                    String value = normalizeIp(cur.toString());
                    if (!value.isEmpty())
                    {
                        out.add(value);
                    }
                    inString = false;
                    continue;
                }

                cur.append(c);
            }
        }
        catch (IOException e)
        {
            dbg("Failed to read %s: %s\n", path, e.getMessage());
        }

        return out;
    }

    private static void saveJsonStringArray(Path path, Set<String> values, String label)
    {
        try
        {
            Files.createDirectories(path.getParent());
            List<String> sorted = new ArrayList<>(values);
            Collections.sort(sorted);

            StringBuilder sb = new StringBuilder();
            sb.append("[\n");
            for (int i = 0; i < sorted.size(); i++)
            {
                if (i > 0)
                {
                    sb.append(",\n");
                }
                sb.append("  \"").append(jsonEscape(sorted.get(i))).append("\"");
            }
            sb.append("\n]\n");

            Files.writeString(path, sb.toString(), StandardCharsets.UTF_8);
        }
        catch (IOException e)
        {
            dbg("Failed to write %s to %s: %s\n", label, path, e.getMessage());
        }
    }

    private static Properties loadServerProperties()
    {
        Properties properties = new Properties();
        Path path = serverPropertiesPath();

        if (!Files.exists(path))
        {
            return properties;
        }

        try (var reader = Files.newBufferedReader(path, StandardCharsets.UTF_8))
        {
            properties.load(reader);
        }
        catch (IOException e)
        {
            dbg("Failed to read %s: %s\n", path, e.getMessage());
        }

        return properties;
    }

    private static int choosePort(String[] args, Properties properties)
    {
        if (args.length >= 1)
        {
            Integer cliPort = parsePort(args[0]);
            if (cliPort != null)
            {
                return cliPort;
            }
            System.err.println("Invalid CLI port: " + args[0] + " (falling back)");
        }

        String propertyPort = properties.getProperty("port");
        if (propertyPort != null)
        {
            Integer parsed = parsePort(propertyPort.trim());
            if (parsed != null)
            {
                return parsed;
            }
            System.err.println("Invalid server.properties port: " + propertyPort + " (falling back)");
        }

        return DEFAULT_PORT;
    }

    private static Integer parsePort(String text)
    {
        try
        {
            int port = Integer.parseInt(text);
            return (port >= 1 && port <= 65535) ? port : null;
        }
        catch (NumberFormatException e)
        {
            return null;
        }
    }

    private static boolean readBoolean(Properties properties, String key, boolean defaultValue)
    {
        String value = properties.getProperty(key);
        if (value == null)
        {
            return defaultValue;
        }

        String lower = value.trim().toLowerCase(Locale.ROOT);
        return lower.equals("true") || lower.equals("1") || lower.equals("yes") || lower.equals("on");
    }

    private static Path serverPropertiesPath()
    {
        return appDir().resolve("server.properties");
    }

    private static Path bannedPlayersPath()
    {
        return appDir().resolve("banned-players.json");
    }

    private static Path whitelistedPlayersPath()
    {
        return appDir().resolve("whitelisted-players.json");
    }

    private static Path appDir()
    {
        try
        {
            CodeSource codeSource = WitcherServer.class.getProtectionDomain().getCodeSource();
            if (codeSource != null && codeSource.getLocation() != null)
            {
                Path path = Paths.get(codeSource.getLocation().toURI()).toAbsolutePath().normalize();
                return Files.isRegularFile(path) ? path.getParent() : path;
            }
        }
        catch (Exception ignored)
        {
        }

        return Paths.get(".").toAbsolutePath().normalize();
    }

    private static String normalizeIp(String ip)
    {
        return stripPort(ip == null ? "" : ip.trim());
    }

    private static String stripPort(String value)
    {
        if (value == null)
        {
            return "";
        }

        String trimmed = value.trim();
        if (trimmed.isEmpty())
        {
            return "";
        }

        if (trimmed.startsWith("[") && trimmed.contains("]"))
        {
            int close = trimmed.indexOf(']');
            return trimmed.substring(1, close);
        }

        long colonCount = trimmed.chars().filter(ch -> ch == ':').count();
        if (colonCount == 1)
        {
            int idx = trimmed.indexOf(':');
            String left = trimmed.substring(0, idx);
            String right = trimmed.substring(idx + 1);
            if (!left.isEmpty() && right.chars().allMatch(Character::isDigit))
            {
                return left;
            }
        }

        return trimmed;
    }

    private static String trimCommandArg(String line, String command)
    {
        return line.length() <= command.length() ? "" : line.substring(command.length()).trim();
    }

    private static String escapeField(String s)
    {
        StringBuilder out = new StringBuilder();

        for (int i = 0; i < s.length(); i++)
        {
            char c = s.charAt(i);

            switch (c)
            {
                case '\\':
                    out.append("\\\\");
                    break;
                case '\t':
                    out.append("\\t");
                    break;
                case '\n':
                    out.append("\\n");
                    break;
                case '\r':
                    out.append("\\r");
                    break;
                default:
                    out.append(c);
                    break;
            }
        }

        return out.toString();
    }

    private static String unescapeField(String s)
    {
        StringBuilder out = new StringBuilder();

        for (int i = 0; i < s.length(); i++)
        {
            char c = s.charAt(i);

            if (c == '\\' && i + 1 < s.length())
            {
                char n = s.charAt(i + 1);

                if (n == 't')
                {
                    out.append('\t');
                    i++;
                }
                else if (n == 'n')
                {
                    out.append('\n');
                    i++;
                }
                else if (n == 'r')
                {
                    out.append('\r');
                    i++;
                }
                else if (n == '\\')
                {
                    out.append('\\');
                    i++;
                }
                else
                {
                    out.append(c);
                }
            }
            else
            {
                out.append(c);
            }
        }

        return out.toString();
    }

    private static String jsonEscape(String s)
    {
        StringBuilder out = new StringBuilder(s.length() + 8);
        for (int i = 0; i < s.length(); i++)
        {
            char c = s.charAt(i);
            if (c == '\\' || c == '"')
            {
                out.append('\\').append(c);
            }
            else if (c >= 0x20)
            {
                out.append(c);
            }
        }
        return out.toString();
    }

    private static void dbgNotime(String format, Object... args)
    {
        System.out.print(String.format(format, args));
        System.out.flush();
    }

    private static void dbg(String format, Object... args)
    {
        String prefix = "[" + LocalTime.now().format(LOG_TIME) + " INFO]: ";
        System.out.print(prefix + String.format(format, args));
        System.out.flush();
    }

    private static String trim(String s)
    {
        return s == null ? "" : s.trim();
    }

    private static String getRegion(String region)
    {
        region = trim(region);

        if (region.equals("1") || region.equals("9"))
        {
            return "Novigrad/Velen";
        }
        else if (region.equals("2"))
        {
            return "Skellige";
        }
        else if (region.equals("3"))
        {
            return "Kaer Morhen";
        }
        else if (region.equals("4") || region.equals("8"))
        {
            return "White Orchard";
        }
        else if (region.equals("5"))
        {
            return "Vizima";
        }
        else if (region.equals("6"))
        {
            return "Isle of Mists";
        }
        else if (region.equals("7"))
        {
            return "Spiral";
        }
        else if (region.equals("11"))
        {
            return "Toussaint";
        }
        else
        {
            return "Unknown";
        }
    }

    private static String getLocation(List<String> fields)
    {
        if (fields == null || fields.size() < 9)
        {
            return "";
        }

        String name = trim(fields.get(8));

        if (name.equals("NR_PlayerManager.Init") || name.equals("Player") || name.isEmpty())
        {
            return "";
        }

        return name;
    }

    private static List<String> getCoords(List<String> fields)
    {
        if (fields == null || fields.size() < 5)
        {
            return Collections.emptyList();
        }

        List<String> out = new ArrayList<>(3);
        out.add(trim(fields.get(2)));
        out.add(trim(fields.get(3)));
        out.add(trim(fields.get(4)));
        return out;
    }

    private static String normalizeUsernameKey(String username)
    {
        return username == null ? "" : username.trim().toLowerCase(Locale.ROOT);
    }

    private static boolean reserveTimedOutPlayer(String usernameKey, PlayerSession session, long now)
    {
        if (!players.remove(usernameKey, session))
        {
            return false;
        }

        String ip = normalizeIp(session.endpoint.address.getHostAddress());
        reservedUsernames.put(usernameKey, new UsernameReservation(
                session.username,
                ip,
                now + USERNAME_HOLD_NANOS
        ));

        dbg("Timed out player %s; reserving username for %d seconds to IP %s\n",
                session.username,
                USERNAME_HOLD_NANOS / 1_000_000_000L,
                ip);

        return true;
    }

    private static PlayerSession findPlayerById(int playerId)
    {
        if (playerId <= 0)
        {
            return null;
        }

        for (PlayerSession session : players.values())
        {
            if (session != null && session.playerId == playerId)
            {
                return session;
            }
        }

        return null;
    }

    private static int allocateNewPlayerId()
    {
        int candidate;

        do
        {
            candidate = nextPlayerId.getAndIncrement();
        }
        while (candidate <= 0 || findPlayerById(candidate) != null);

        return candidate;
    }

    private static void bumpNextPlayerIdPast(int usedId)
    {
        if (usedId <= 0)
        {
            return;
        }

        while (true)
        {
            int current = nextPlayerId.get();

            if (current > usedId)
            {
                return;
            }

            if (nextPlayerId.compareAndSet(current, usedId + 1))
            {
                return;
            }
        }
    }
}