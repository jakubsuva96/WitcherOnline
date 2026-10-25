import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public class PlayerSession
{
    public final int playerId;
    public final String username;
    public volatile ClientEndpoint endpoint;
    public volatile long lastSeen;

    public volatile List<String> update1AFields = Collections.emptyList();
    public volatile List<String> update1BFields = Collections.emptyList();
    public volatile List<String> update2AFields = Collections.emptyList();
    public volatile List<String> update2BFields = Collections.emptyList();
    public volatile List<String> update3Fields = Collections.emptyList();
    public volatile List<String> update4Fields = Collections.emptyList();

    // co-op state by channel (first field): latest value, forwarded on arrival and rebroadcast like the updates above
    public final Map<String, List<String>> coopFields = new ConcurrentHashMap<>();
    // when each channel was last forwarded on arrival (System.nanoTime): the broadcast tick doesn't repeat it so soon
    public final Map<String, Long> coopForwardedAt = new ConcurrentHashMap<>();
    // when each channel last arrived from the player: a channel the player stopped sending (its role changed) goes stale
    public final Map<String, Long> coopReceivedAt = new ConcurrentHashMap<>();

    // version handshake (HELLO): sessions without one are dropped after a grace period
    public final long createdAt;
    public volatile boolean helloSeen = false;
    public volatile String modVersion = "";
    public volatile String gameVersion = "";

    public PlayerSession(int playerId, String username, ClientEndpoint endpoint, long lastSeen)
    {
        this.playerId = playerId;
        this.username = username;
        this.endpoint = endpoint;
        this.lastSeen = lastSeen;
        this.createdAt = lastSeen;
    }
}