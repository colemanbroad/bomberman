// Zero-dependency automatic port forwarding (UPnP IGD + NAT-PMP) for macOS/Linux/Windows.
// Maps TCP and UDP on the requested port, queries external IP, and detects CGNAT/double-NAT.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET usock_t;
#define UBAD INVALID_SOCKET
#define UCLOSE(s) closesocket(s)
#else
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
typedef int usock_t;
#define UBAD (-1)
#define UCLOSE(s) close(s)
#endif

typedef struct { uint8_t *data; int64_t len; } ub_slice;

// Saved state for clean unmapping when switching modes or exiting.
static int g_method = 0; // 0 = none, 1 = UPnP, 2 = NAT-PMP
static char g_ctrl_host[128];
static int g_ctrl_port = 80;
static char g_ctrl_path[256];
static char g_service[128];
static char g_gw_ip[64];
static int g_mapped_port = 0;

static void net_init(void) {
#ifdef _WIN32
    WSADATA w;
    WSAStartup(MAKEWORD(2, 2), &w);
#endif
}

static void set_timeouts(usock_t s, int ms) {
#ifdef _WIN32
    DWORD t = (DWORD)ms;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&t, sizeof t);
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&t, sizeof t);
#else
    struct timeval tv;
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
#endif
}

static int get_local_ipv4(char *out, size_t cap) {
    usock_t s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s == UBAD) return 0;
    struct sockaddr_in dst;
    memset(&dst, 0, sizeof dst);
    dst.sin_family = AF_INET;
    dst.sin_port = htons(53);
    dst.sin_addr.s_addr = htonl(0x08080808);
    int ok = connect(s, (struct sockaddr *)&dst, sizeof dst) == 0;
    struct sockaddr_in loc;
    memset(&loc, 0, sizeof loc);
#ifdef _WIN32
    int len = (int)sizeof loc;
#else
    socklen_t len = sizeof loc;
#endif
    if (ok) ok = getsockname(s, (struct sockaddr *)&loc, &len) == 0;
    UCLOSE(s);
    if (!ok) return 0;
#ifdef _WIN32
    return inet_ntop(AF_INET, &loc.sin_addr, out, cap) != NULL;
#else
    return inet_ntop(AF_INET, &loc.sin_addr, out, (socklen_t)cap) != NULL;
#endif
}

static int is_private_or_cgnat(const char *ip) {
    struct in_addr a;
    if (inet_pton(AF_INET, ip, &a) != 1) return 1;
    uint32_t h = ntohl(a.s_addr);
    unsigned b0 = (h >> 24) & 255;
    unsigned b1 = (h >> 16) & 255;
    if (b0 == 0 || b0 == 10 || b0 == 127) return 1;
    if (b0 == 100 && b1 >= 64 && b1 <= 127) return 1; // RFC 6598 CGNAT
    if (b0 == 169 && b1 == 254) return 1;
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return 1;
    if (b0 == 192 && b1 == 168) return 1;
    return 0;
}

static const char *ci_strstr(const char *hay, const char *needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0) return hay;
    for (const char *p = hay; *p; p++) {
        size_t i = 0;
        while (i < nlen && p[i] && tolower((unsigned char)p[i]) == tolower((unsigned char)needle[i])) i++;
        if (i == nlen) return p;
    }
    return NULL;
}

static int parse_http_url(const char *url, char *host, size_t hcap, int *port, char *path, size_t pcap) {
    const char *p = ci_strstr(url, "http://");
    if (!p) return 0;
    p += 7;
    const char *slash = strchr(p, '/');
    const char *hend = slash ? slash : p + strlen(p);
    const char *colon = NULL;
    for (const char *q = p; q < hend; q++) if (*q == ':') { colon = q; break; }
    size_t hlen = (size_t)((colon ? colon : hend) - p);
    if (hlen == 0 || hlen >= hcap) return 0;
    memcpy(host, p, hlen);
    host[hlen] = 0;
    *port = colon ? atoi(colon + 1) : 80;
    if (*port <= 0 || *port > 65535) *port = 80;
    if (slash) {
        size_t plen = strlen(slash);
        if (plen >= pcap) plen = pcap - 1;
        memcpy(path, slash, plen);
        path[plen] = 0;
    } else {
        snprintf(path, pcap, "/");
    }
    return 1;
}

static int http_exchange(const char *host, int port, const char *req, char *resp, int rcap, int timeout_ms) {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char pstr[16];
    snprintf(pstr, sizeof pstr, "%d", port);
    if (getaddrinfo(host, pstr, &hints, &res) != 0 || !res) return -1;
    usock_t s = socket(AF_INET, SOCK_STREAM, 0);
    if (s == UBAD) { freeaddrinfo(res); return -1; }
    set_timeouts(s, timeout_ms);
    int ok = connect(s, res->ai_addr, (int)res->ai_addrlen) == 0;
    freeaddrinfo(res);
    if (!ok) { UCLOSE(s); return -1; }
    int req_len = (int)strlen(req);
    int sent = 0;
    while (sent < req_len) {
        int n = (int)send(s, req + sent, req_len - sent, 0);
        if (n <= 0) { UCLOSE(s); return -1; }
        sent += n;
    }
    int tot = 0;
    while (tot < rcap - 1) {
        int n = (int)recv(s, resp + tot, rcap - 1 - tot, 0);
        if (n <= 0) break;
        tot += n;
    }
    resp[tot] = 0;
    UCLOSE(s);
    return tot;
}

static int xml_extract(const char *xml, const char *tag, char *out, size_t cap) {
    char open_t[96], close_t[96];
    snprintf(open_t, sizeof open_t, "<%s>", tag);
    snprintf(close_t, sizeof close_t, "</%s>", tag);
    const char *a = ci_strstr(xml, open_t);
    if (!a) return 0;
    a += strlen(open_t);
    const char *b = ci_strstr(a, close_t);
    if (!b) return 0;
    while (a < b && isspace((unsigned char)*a)) a++;
    while (b > a && isspace((unsigned char)b[-1])) b--;
    size_t n = (size_t)(b - a);
    if (n == 0 || n >= cap) return 0;
    memcpy(out, a, n);
    out[n] = 0;
    return 1;
}

static int upnp_discover(char *loc_url, size_t cap) {
    usock_t s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s == UBAD) return 0;
    set_timeouts(s, 450);
    struct sockaddr_in dst;
    memset(&dst, 0, sizeof dst);
    dst.sin_family = AF_INET;
    dst.sin_port = htons(1900);
    inet_pton(AF_INET, "239.255.255.250", &dst.sin_addr);

    static const char *sts[3] = {
        "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
        "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1"
    };
    char req[512];
    for (int i = 0; i < 3; i++) {
        int n = snprintf(req, sizeof req,
            "M-SEARCH * HTTP/1.1\r\n"
            "HOST: 239.255.255.250:1900\r\n"
            "MAN: \"ssdp:discover\"\r\n"
            "MX: 1\r\n"
            "ST: %s\r\n\r\n", sts[i]);
        sendto(s, req, n, 0, (struct sockaddr *)&dst, sizeof dst);
    }

    char buf[2048];
    for (int tries = 0; tries < 6; tries++) {
        int r = (int)recvfrom(s, buf, (int)sizeof(buf) - 1, 0, NULL, NULL);
        if (r <= 0) break;
        buf[r] = 0;
        const char *l = ci_strstr(buf, "\nlocation:");
        if (!l) l = ci_strstr(buf, "location:");
        if (!l) continue;
        const char *v = strchr(l, ':');
        if (!v) continue;
        v++;
        while (*v == ' ' || *v == '\t') v++;
        const char *e = v;
        while (*e && *e != '\r' && *e != '\n') e++;
        size_t len = (size_t)(e - v);
        if (len > 7 && len < cap) {
            memcpy(loc_url, v, len);
            loc_url[len] = 0;
            UCLOSE(s);
            return 1;
        }
    }
    UCLOSE(s);
    return 0;
}

static int upnp_find_control(const char *loc_url, char *chost, size_t hcap, int *cport, char *cpath, size_t pcap, char *svc, size_t scap) {
    char host[128], path[256];
    int port = 80;
    if (!parse_http_url(loc_url, host, sizeof host, &port, path, sizeof path)) return 0;

    char req[512];
    snprintf(req, sizeof req,
        "GET %s HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "Connection: close\r\n\r\n", path, host, port);

    char *xml = (char *)malloc(65536);
    if (!xml) return 0;
    int got = http_exchange(host, port, req, xml, 65536, 1500);
    if (got <= 0) { free(xml); return 0; }

    static const char *targets[3] = {
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANPPPConnection:1"
    };
    int found = 0;
    for (int t = 0; t < 3 && !found; t++) {
        const char *pos = xml;
        while ((pos = ci_strstr(pos, targets[t])) != NULL) {
            // Walk back slightly or search forward within this <service> block for <controlURL>
            const char *end_svc = ci_strstr(pos, "</service>");
            const char *cu = ci_strstr(pos, "<controlURL>");
            if (cu && (!end_svc || cu < end_svc)) {
                char raw[256];
                if (xml_extract(cu, "controlURL", raw, sizeof raw)) {
                    snprintf(svc, scap, "%s", targets[t]);
                    if (ci_strstr(raw, "http://") == raw) {
                        found = parse_http_url(raw, chost, hcap, cport, cpath, pcap);
                    } else {
                        snprintf(chost, hcap, "%s", host);
                        *cport = port;
                        if (raw[0] == '/') snprintf(cpath, pcap, "%s", raw);
                        else snprintf(cpath, pcap, "/%s", raw);
                        found = 1;
                    }
                    break;
                }
            }
            pos += strlen(targets[t]);
        }
    }
    free(xml);
    return found;
}

static int upnp_soap(const char *host, int port, const char *path, const char *svc,
                     const char *action, const char *body, char *resp, int rcap, int timeout_ms) {
    char soap[1536];
    int blen = snprintf(soap, sizeof soap,
        "<?xml version=\"1.0\"?>"
        "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
        "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
        "<s:Body><u:%s xmlns:u=\"%s\">%s</u:%s></s:Body></s:Envelope>",
        action, svc, body, action);
    char req[2560];
    snprintf(req, sizeof req,
        "POST %s HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "Content-Type: text/xml; charset=\"utf-8\"\r\n"
        "SOAPAction: \"%s#%s\"\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n\r\n%s",
        path, host, port, svc, action, blen, soap);
    int n = http_exchange(host, port, req, resp, rcap, timeout_ms);
    if (n <= 0) return 0;
    return ci_strstr(resp, "200 OK") != NULL;
}

static int upnp_add_one(const char *host, int port, const char *path, const char *svc,
                        const char *local_ip, int ext_port, const char *proto, int lease) {
    char body[512], resp[2048];
    snprintf(body, sizeof body,
        "<NewRemoteHost></NewRemoteHost>"
        "<NewExternalPort>%d</NewExternalPort>"
        "<NewProtocol>%s</NewProtocol>"
        "<NewInternalPort>%d</NewInternalPort>"
        "<NewInternalClient>%s</NewInternalClient>"
        "<NewEnabled>1</NewEnabled>"
        "<NewPortMappingDescription>Goose Bomberman</NewPortMappingDescription>"
        "<NewLeaseDuration>%d</NewLeaseDuration>",
        ext_port, proto, ext_port, local_ip, lease);
    if (upnp_soap(host, port, path, svc, "AddPortMapping", body, resp, sizeof resp, 1500)) return 1;
    // Some routers require permanent lease (0) and return error 725.
    if (lease != 0 && strstr(resp, "725") != NULL) {
        return upnp_add_one(host, port, path, svc, local_ip, ext_port, proto, 0);
    }
    return 0;
}

static int upnp_del_one(const char *host, int port, const char *path, const char *svc,
                        int ext_port, const char *proto) {
    char body[256], resp[1024];
    snprintf(body, sizeof body,
        "<NewRemoteHost></NewRemoteHost>"
        "<NewExternalPort>%d</NewExternalPort>"
        "<NewProtocol>%s</NewProtocol>",
        ext_port, proto);
    return upnp_soap(host, port, path, svc, "DeletePortMapping", body, resp, sizeof resp, 600);
}

// NAT-PMP (RFC 6886) fallback: try <subnet>.1 on UDP 5351.
static int natpmp_try(const char *local_ip, int port, char *pub_out, size_t pcap) {
    struct in_addr a;
    if (inet_pton(AF_INET, local_ip, &a) != 1) return 0;
    uint32_t h = ntohl(a.s_addr);
    struct in_addr gw;
    gw.s_addr = htonl((h & 0xFFFFFF00u) | 1u);
    char gw_str[64];
    if (!inet_ntop(AF_INET, &gw, gw_str, sizeof gw_str)) return 0;

    usock_t s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s == UBAD) return 0;
    set_timeouts(s, 450);

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof dst);
    dst.sin_family = AF_INET;
    dst.sin_port = htons(5351);
    dst.sin_addr = gw;

    // 1) Request public address (ver=0, op=0)
    uint8_t req_ip[2] = {0, 0};
    sendto(s, (const char *)req_ip, 2, 0, (struct sockaddr *)&dst, sizeof dst);
    uint8_t resp[32];
    int r = (int)recvfrom(s, (char *)resp, sizeof resp, 0, NULL, NULL);
    if (r < 12 || resp[0] != 0 || resp[1] != 128 || resp[2] != 0 || resp[3] != 0) {
        UCLOSE(s);
        return 0;
    }
    snprintf(pub_out, pcap, "%u.%u.%u.%u", resp[8], resp[9], resp[10], resp[11]);

    // 2) Map UDP (op=1) and TCP (op=2) for 3600 seconds
    int mapped = 0;
    for (int op = 1; op <= 2; op++) {
        uint8_t m[12];
        memset(m, 0, sizeof m);
        m[0] = 0;
        m[1] = (uint8_t)op;
        m[4] = (uint8_t)((port >> 8) & 255);
        m[5] = (uint8_t)(port & 255);
        m[6] = (uint8_t)((port >> 8) & 255);
        m[7] = (uint8_t)(port & 255);
        uint32_t life = 3600;
        m[8] = (uint8_t)((life >> 24) & 255);
        m[9] = (uint8_t)((life >> 16) & 255);
        m[10] = (uint8_t)((life >> 8) & 255);
        m[11] = (uint8_t)(life & 255);
        sendto(s, (const char *)m, 12, 0, (struct sockaddr *)&dst, sizeof dst);
        r = (int)recvfrom(s, (char *)resp, sizeof resp, 0, NULL, NULL);
        if (r >= 16 && resp[0] == 0 && resp[1] == (uint8_t)(128 + op) && resp[2] == 0 && resp[3] == 0) {
            mapped++;
        }
    }
    UCLOSE(s);
    if (mapped == 2) {
        snprintf(g_gw_ip, sizeof g_gw_ip, "%s", gw_str);
        g_method = 2;
        g_mapped_port = port;
        return 1;
    }
    return 0;
}

static void write_slice(ub_slice dst, int64_t *out_len, const char *src) {
    int64_t n = (int64_t)strlen(src);
    if (n > dst.len) n = dst.len;
    if (n > 0) memcpy(dst.data, src, (size_t)n);
    *out_len = n;
}

// Removes any previously created UPnP or NAT-PMP mapping.
int64_t upnp_unmap(int64_t port) {
    if (g_method == 0) return 0;
    int p = port > 0 ? (int)port : g_mapped_port;
    if (p <= 0) return 0;
    net_init();
    if (g_method == 1) {
        upnp_del_one(g_ctrl_host, g_ctrl_port, g_ctrl_path, g_service, p, "TCP");
        upnp_del_one(g_ctrl_host, g_ctrl_port, g_ctrl_path, g_service, p, "UDP");
    } else if (g_method == 2) {
        usock_t s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s != UBAD) {
            set_timeouts(s, 300);
            struct sockaddr_in dst;
            memset(&dst, 0, sizeof dst);
            dst.sin_family = AF_INET;
            dst.sin_port = htons(5351);
            inet_pton(AF_INET, g_gw_ip, &dst.sin_addr);
            for (int op = 1; op <= 2; op++) {
                uint8_t m[12];
                memset(m, 0, sizeof m);
                m[1] = (uint8_t)op;
                m[4] = (uint8_t)((p >> 8) & 255);
                m[5] = (uint8_t)(p & 255);
                sendto(s, (const char *)m, 12, 0, (struct sockaddr *)&dst, sizeof dst);
            }
            UCLOSE(s);
        }
    }
    g_method = 0;
    g_mapped_port = 0;
    return 1;
}

// Attempts UPnP IGD then NAT-PMP to forward TCP+UDP on `port`.
// Returns: 0 = mapped with public IP, 1 = mapped but CGNAT/double-NAT detected, -1 = failed.
int64_t upnp_map(int64_t port, ub_slice pub_ip, int64_t *pub_len, ub_slice msg, int64_t *msg_len) {
    net_init();
    *pub_len = 0;
    *msg_len = 0;
    if (g_method != 0) upnp_unmap(g_mapped_port);

    char local_ip[64];
    if (!get_local_ipv4(local_ip, sizeof local_ip)) {
        write_slice(msg, msg_len, "No local network interface found");
        return -1;
    }

    char pub[64] = {0};
    char loc_url[256] = {0};
    int ok = 0;
    const char *via = "";

    // 1) Try UPnP IGD
    if (upnp_discover(loc_url, sizeof loc_url)) {
        char chost[128], cpath[256], svc[128];
        int cport = 80;
        if (upnp_find_control(loc_url, chost, sizeof chost, &cport, cpath, sizeof cpath, svc, sizeof svc)) {
            int ok_tcp = upnp_add_one(chost, cport, cpath, svc, local_ip, (int)port, "TCP", 3600);
            int ok_udp = upnp_add_one(chost, cport, cpath, svc, local_ip, (int)port, "UDP", 3600);
            if (ok_tcp && ok_udp) {
                snprintf(g_ctrl_host, sizeof g_ctrl_host, "%s", chost);
                g_ctrl_port = cport;
                snprintf(g_ctrl_path, sizeof g_ctrl_path, "%s", cpath);
                snprintf(g_service, sizeof g_service, "%s", svc);
                g_method = 1;
                g_mapped_port = (int)port;
                char resp[2048];
                if (upnp_soap(chost, cport, cpath, svc, "GetExternalIPAddress", "", resp, sizeof resp, 1200)) {
                    xml_extract(resp, "NewExternalIPAddress", pub, sizeof pub);
                }
                ok = 1;
                via = "UPnP";
            }
        }
    }

    // 2) Fallback to NAT-PMP
    if (!ok) {
        if (natpmp_try(local_ip, (int)port, pub, sizeof pub)) {
            ok = 1;
            via = "NAT-PMP";
        }
    }

    if (!ok) {
        write_slice(msg, msg_len, "Router UPnP/NAT-PMP unavailable (forward port manually or use playit.gg)");
        return -1;
    }

    if (pub[0] == 0) {
        char note[160];
        snprintf(note, sizeof note, "Mapped via %s (check whatismyip.com for public IP)", via);
        write_slice(msg, msg_len, note);
        return 0;
    }

    write_slice(pub_ip, pub_len, pub);
    if (is_private_or_cgnat(pub)) {
        char note[160];
        snprintf(note, sizeof note, "Mapped via %s, but ISP uses CGNAT/double-NAT (%s) - use playit.gg", via, pub);
        write_slice(msg, msg_len, note);
        return 1;
    }

    char note[160];
    snprintf(note, sizeof note, "Port %d open via %s", (int)port, via);
    write_slice(msg, msg_len, note);
    return 0;
}
