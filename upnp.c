// Zero-dependency automatic port forwarding (UPnP IGD + NAT-PMP + PCP v2) for macOS/Linux/Windows.
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
#include <ifaddrs.h>
#include <net/if.h>
typedef int usock_t;
#define UBAD (-1)
#define UCLOSE(s) close(s)
#endif

typedef struct { uint8_t *data; int64_t len; } ub_slice;

// Saved state for clean unmapping when switching modes or exiting.
static int g_method = 0; // 0 = none, 1 = UPnP, 2 = NAT-PMP, 3 = PCP v2
static char g_ctrl_host[128];
static int g_ctrl_port = 80;
static char g_ctrl_path[256];
static char g_service[128];
static char g_gw_ip[64];
static char g_lan_ip[64];
static uint8_t g_pcp_nonce[12];
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

static int64_t now_ms(void) {
#ifdef _WIN32
    return (int64_t)GetTickCount64();
#else
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + (int64_t)(tv.tv_usec / 1000);
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

static int is_rfc1918(uint32_t h) {
    unsigned b0 = (h >> 24) & 255;
    unsigned b1 = (h >> 16) & 255;
    if (b0 == 10) return 1;
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return 1;
    if (b0 == 192 && b1 == 168) return 1;
    return 0;
}

static int add_ip_unique(char ips[][64], int count, int max_ips, const char *ip) {
    if (count >= max_ips || !ip || !ip[0]) return count;
    for (int i = 0; i < count; i++) {
        if (strcmp(ips[i], ip) == 0) return count;
    }
    snprintf(ips[count], 64, "%s", ip);
    return count + 1;
}

// Collect real broadcast-capable LAN IPv4 addresses (skipping VPN utun / point-to-point interfaces).
static int get_lan_ipv4s(char ips[][64], int max_ips) {
    int count = 0;
#ifndef _WIN32
    struct ifaddrs *ifas = NULL;
    if (getifaddrs(&ifas) == 0 && ifas) {
        // Pass 1: RFC1918 broadcast LAN interfaces (en0, eth0, wlan0, etc.), skipping VPN/utun (IFF_POINTOPOINT).
        // Pass 2: Any remaining non-loopback, non-link-local, non-point-to-point IPv4 interface.
        for (int pass = 0; pass < 2; pass++) {
            for (struct ifaddrs *ifa = ifas; ifa; ifa = ifa->ifa_next) {
                if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
                unsigned fl = ifa->ifa_flags;
                if (!(fl & IFF_UP) || !(fl & IFF_RUNNING)) continue;
                if ((fl & IFF_LOOPBACK) || (fl & IFF_POINTOPOINT)) continue;
                if (!(fl & IFF_BROADCAST)) continue;
                struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
                uint32_t h = ntohl(sin->sin_addr.s_addr);
                unsigned b0 = (h >> 24) & 255;
                unsigned b1 = (h >> 16) & 255;
                if (b0 == 0 || b0 == 127 || (b0 == 169 && b1 == 254)) continue;
                if (pass == 0 && !is_rfc1918(h)) continue;
                char buf[64];
                if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof buf)) {
                    count = add_ip_unique(ips, count, max_ips, buf);
                }
            }
        }
        freeifaddrs(ifas);
    }
#else
    char hname[256];
    if (gethostname(hname, sizeof hname) == 0) {
        struct addrinfo hints, *res = NULL;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_INET;
        if (getaddrinfo(hname, NULL, &hints, &res) == 0 && res) {
            for (int pass = 0; pass < 2; pass++) {
                for (struct addrinfo *p = res; p; p = p->ai_next) {
                    struct sockaddr_in *sin = (struct sockaddr_in *)p->ai_addr;
                    uint32_t h = ntohl(sin->sin_addr.s_addr);
                    unsigned b0 = (h >> 24) & 255;
                    unsigned b1 = (h >> 16) & 255;
                    if (b0 == 0 || b0 == 127 || (b0 == 169 && b1 == 254)) continue;
                    if (pass == 0 && !is_rfc1918(h)) continue;
                    char buf[64];
                    if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof buf)) {
                        count = add_ip_unique(ips, count, max_ips, buf);
                    }
                }
            }
            freeaddrinfo(res);
        }
    }
#endif
    // Fallback: route-selected local IP toward 8.8.8.8
    usock_t s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s != UBAD) {
        struct sockaddr_in dst;
        memset(&dst, 0, sizeof dst);
        dst.sin_family = AF_INET;
        dst.sin_port = htons(53);
        dst.sin_addr.s_addr = htonl(0x08080808);
        if (connect(s, (struct sockaddr *)&dst, sizeof dst) == 0) {
            struct sockaddr_in loc;
            memset(&loc, 0, sizeof loc);
#ifdef _WIN32
            int len = (int)sizeof loc;
#else
            socklen_t len = sizeof loc;
#endif
            if (getsockname(s, (struct sockaddr *)&loc, &len) == 0) {
                char buf[64];
                if (inet_ntop(AF_INET, &loc.sin_addr, buf, sizeof buf)) {
                    count = add_ip_unique(ips, count, max_ips, buf);
                }
            }
        }
        UCLOSE(s);
    }
    return count;
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

// Discover ALL unique SSDP device Location URLs on `local_ip` (multicast + unicast to gateway) over ~1200ms.
static int upnp_discover_all(const char *local_ip, const char *gw_ip, char urls[][256], int max_urls) {
    usock_t s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s == UBAD) return 0;

    struct in_addr lip_addr;
    if (inet_pton(AF_INET, local_ip, &lip_addr) != 1) { UCLOSE(s); return 0; }

    // Bind explicitly to the LAN interface and set IP_MULTICAST_IF so VPN tunnels don't hijack SSDP!
    struct sockaddr_in loc;
    memset(&loc, 0, sizeof loc);
    loc.sin_family = AF_INET;
    loc.sin_addr = lip_addr;
    loc.sin_port = 0;
    bind(s, (struct sockaddr *)&loc, sizeof loc);
    setsockopt(s, IPPROTO_IP, IP_MULTICAST_IF, (const char *)&lip_addr, sizeof lip_addr);
    unsigned char ttl = 2;
    setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, (const char *)&ttl, sizeof ttl);
    set_timeouts(s, 250);

    struct sockaddr_in mcast;
    memset(&mcast, 0, sizeof mcast);
    mcast.sin_family = AF_INET;
    mcast.sin_port = htons(1900);
    inet_pton(AF_INET, "239.255.255.250", &mcast.sin_addr);

    struct sockaddr_in ucast;
    memset(&ucast, 0, sizeof ucast);
    ucast.sin_family = AF_INET;
    ucast.sin_port = htons(1900);
    int has_gw = gw_ip && gw_ip[0] && inet_pton(AF_INET, gw_ip, &ucast.sin_addr) == 1;

    static const char *sts[5] = {
        "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
        "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
        "upnp:rootdevice"
    };
    char req[512];
    for (int i = 0; i < 5; i++) {
        int n = snprintf(req, sizeof req,
            "M-SEARCH * HTTP/1.1\r\n"
            "HOST: 239.255.255.250:1900\r\n"
            "MAN: \"ssdp:discover\"\r\n"
            "MX: 1\r\n"
            "ST: %s\r\n\r\n", sts[i]);
        sendto(s, req, n, 0, (struct sockaddr *)&mcast, sizeof mcast);
        if (has_gw && i < 2) {
            sendto(s, req, n, 0, (struct sockaddr *)&ucast, sizeof ucast);
        }
    }

    int count = 0;
    int64_t deadline = now_ms() + 1250;
    char buf[4096];
    while (count < max_urls && now_ms() < deadline) {
        int r = (int)recvfrom(s, buf, (int)sizeof(buf) - 1, 0, NULL, NULL);
        if (r <= 0) continue;
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
        if (len > 7 && len < 255) {
            char tmp[256];
            memcpy(tmp, v, len);
            tmp[len] = 0;
            int dup = 0;
            for (int k = 0; k < count; k++) if (strcmp(urls[k], tmp) == 0) { dup = 1; break; }
            if (!dup) {
                snprintf(urls[count], 256, "%s", tmp);
                count++;
            }
        }
    }
    UCLOSE(s);
    return count;
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

    // Respect optional <URLBase> if the router specifies one
    char base_host[128];
    int base_port = port;
    char base_path[256];
    snprintf(base_host, sizeof base_host, "%s", host);
    base_path[0] = 0;
    char ubase[256];
    if (xml_extract(xml, "URLBase", ubase, sizeof ubase)) {
        parse_http_url(ubase, base_host, sizeof base_host, &base_port, base_path, sizeof base_path);
    }

    static const char *targets[3] = {
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANPPPConnection:1"
    };
    int found = 0;
    // Scan each <service>...</service> block so <controlURL> is found whether before or after <serviceType>!
    const char *sv = xml;
    while (!found && (sv = ci_strstr(sv, "<service>")) != NULL) {
        const char *sv_end = ci_strstr(sv, "</service>");
        if (!sv_end) break;
        size_t blen = (size_t)(sv_end - sv);
        if (blen < 2048) {
            char blk[2048];
            memcpy(blk, sv, blen);
            blk[blen] = 0;
            for (int t = 0; t < 3 && !found; t++) {
                if (ci_strstr(blk, targets[t])) {
                    char raw[256];
                    if (xml_extract(blk, "controlURL", raw, sizeof raw)) {
                        snprintf(svc, scap, "%s", targets[t]);
                        if (ci_strstr(raw, "http://") == raw) {
                            found = parse_http_url(raw, chost, hcap, cport, cpath, pcap);
                        } else {
                            snprintf(chost, hcap, "%s", base_host);
                            *cport = base_port;
                            if (raw[0] == '/') snprintf(cpath, pcap, "%s", raw);
                            else snprintf(cpath, pcap, "/%s", raw);
                            found = 1;
                        }
                    }
                }
            }
        }
        sv = sv_end + 10;
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
    // Many routers require permanent lease (0) and return UPnP error 725 (OnlyPermanentLeasesSupported).
    if (lease != 0) {
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

// NAT-PMP (RFC 6886) on <gw_ip>:5351 bound explicitly to local_ip.
static int natpmp_try_gw(const char *local_ip, const char *gw_str, int port, char *pub_out, size_t pcap) {
    struct in_addr lip, gw;
    if (inet_pton(AF_INET, local_ip, &lip) != 1 || inet_pton(AF_INET, gw_str, &gw) != 1) return 0;

    usock_t s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s == UBAD) return 0;
    struct sockaddr_in loc;
    memset(&loc, 0, sizeof loc);
    loc.sin_family = AF_INET;
    loc.sin_addr = lip;
    bind(s, (struct sockaddr *)&loc, sizeof loc);
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
        snprintf(g_lan_ip, sizeof g_lan_ip, "%s", local_ip);
        g_method = 2;
        g_mapped_port = port;
        return 1;
    }
    return 0;
}

// PCP v2 (RFC 6887) MAP fallback on <gw_ip>:5351 for modern routers that disable UPnP/NAT-PMP v0.
static int pcp_send_map(usock_t s, const struct sockaddr_in *dst, const struct in_addr *lip,
                        const uint8_t nonce[12], uint8_t proto, int port, uint32_t life,
                        char *pub_out, size_t pcap) {
    uint8_t req[60];
    memset(req, 0, sizeof req);
    req[0] = 2; // PCP version 2
    req[1] = 1; // MAP opcode
    req[4] = (uint8_t)((life >> 24) & 255);
    req[5] = (uint8_t)((life >> 16) & 255);
    req[6] = (uint8_t)((life >> 8) & 255);
    req[7] = (uint8_t)(life & 255);
    // IPv4-mapped IPv6 client address at bytes 8..23
    req[18] = 0xff; req[19] = 0xff;
    memcpy(req + 20, &lip->s_addr, 4);
    // MAP payload at bytes 24..59: 12-byte nonce, proto, 3 reserved, internal port, external port, suggested external IP
    memcpy(req + 24, nonce, 12);
    req[36] = proto; // 6 = TCP, 17 = UDP
    req[40] = (uint8_t)((port >> 8) & 255);
    req[41] = (uint8_t)(port & 255);
    req[42] = (uint8_t)((port >> 8) & 255);
    req[43] = (uint8_t)(port & 255);
    req[54] = 0xff; req[55] = 0xff; // ::ffff:0.0.0.0 (let router assign external IPv4)
    sendto(s, (const char *)req, sizeof req, 0, (const struct sockaddr *)dst, sizeof *dst);
    uint8_t resp[128];
    int r = (int)recvfrom(s, (char *)resp, sizeof resp, 0, NULL, NULL);
    if (r >= 60 && resp[0] == 2 && resp[1] == 129 && resp[3] == 0) {
        if (pub_out && pcap > 0 && resp[54] == 0xff && resp[55] == 0xff) {
            snprintf(pub_out, pcap, "%u.%u.%u.%u", resp[56], resp[57], resp[58], resp[59]);
        }
        return 1;
    }
    return 0;
}

static int pcp_try_gw(const char *local_ip, const char *gw_str, int port, char *pub_out, size_t pcap) {
    struct in_addr lip, gw;
    if (inet_pton(AF_INET, local_ip, &lip) != 1 || inet_pton(AF_INET, gw_str, &gw) != 1) return 0;

    usock_t s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s == UBAD) return 0;
    struct sockaddr_in loc;
    memset(&loc, 0, sizeof loc);
    loc.sin_family = AF_INET;
    loc.sin_addr = lip;
    bind(s, (struct sockaddr *)&loc, sizeof loc);
    set_timeouts(s, 450);

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof dst);
    dst.sin_family = AF_INET;
    dst.sin_port = htons(5351);
    dst.sin_addr = gw;

    uint8_t nonce[12];
    int64_t seed = now_ms() ^ (int64_t)port;
    for (int i = 0; i < 12; i++) {
        seed = seed * 6364136223846793005LL + 1442695040888963407LL;
        nonce[i] = (uint8_t)((seed >> 24) & 255);
    }

    int ok_tcp = pcp_send_map(s, &dst, &lip, nonce, 6, port, 3600, pub_out, pcap);
    int ok_udp = pcp_send_map(s, &dst, &lip, nonce, 17, port, 3600, pub_out[0] ? NULL : pub_out, pcap);
    UCLOSE(s);
    if (ok_tcp && ok_udp) {
        snprintf(g_gw_ip, sizeof g_gw_ip, "%s", gw_str);
        snprintf(g_lan_ip, sizeof g_lan_ip, "%s", local_ip);
        memcpy(g_pcp_nonce, nonce, 12);
        g_method = 3;
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

// Removes any previously created UPnP, NAT-PMP, or PCP mapping.
int64_t upnp_unmap(int64_t port) {
    if (g_method == 0) return 0;
    int p = port > 0 ? (int)port : g_mapped_port;
    if (p <= 0) return 0;
    net_init();
    if (g_method == 1) {
        upnp_del_one(g_ctrl_host, g_ctrl_port, g_ctrl_path, g_service, p, "TCP");
        upnp_del_one(g_ctrl_host, g_ctrl_port, g_ctrl_path, g_service, p, "UDP");
    } else if (g_method == 2 || g_method == 3) {
        usock_t s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s != UBAD) {
            struct in_addr lip, gw;
            if (inet_pton(AF_INET, g_lan_ip, &lip) == 1) {
                struct sockaddr_in loc;
                memset(&loc, 0, sizeof loc);
                loc.sin_family = AF_INET;
                loc.sin_addr = lip;
                bind(s, (struct sockaddr *)&loc, sizeof loc);
            }
            set_timeouts(s, 300);
            struct sockaddr_in dst;
            memset(&dst, 0, sizeof dst);
            dst.sin_family = AF_INET;
            dst.sin_port = htons(5351);
            inet_pton(AF_INET, g_gw_ip, &dst.sin_addr);
            if (g_method == 2) {
                for (int op = 1; op <= 2; op++) {
                    uint8_t m[12];
                    memset(m, 0, sizeof m);
                    m[1] = (uint8_t)op;
                    m[4] = (uint8_t)((p >> 8) & 255);
                    m[5] = (uint8_t)(p & 255);
                    sendto(s, (const char *)m, 12, 0, (struct sockaddr *)&dst, sizeof dst);
                }
            } else if (inet_pton(AF_INET, g_lan_ip, &lip) == 1 && inet_pton(AF_INET, g_gw_ip, &gw) == 1) {
                pcp_send_map(s, &dst, &lip, g_pcp_nonce, 6, p, 0, NULL, 0);
                pcp_send_map(s, &dst, &lip, g_pcp_nonce, 17, p, 0, NULL, 0);
            }
            UCLOSE(s);
        }
    }
    g_method = 0;
    g_mapped_port = 0;
    return 1;
}

// Attempts UPnP IGD, NAT-PMP, then PCP v2 across real LAN interfaces to forward TCP+UDP on `port`.
// Returns: 0 = mapped with public IP, 1 = mapped but CGNAT/double-NAT detected, -1 = failed.
int64_t upnp_map(int64_t port, ub_slice pub_ip, int64_t *pub_len, ub_slice msg, int64_t *msg_len) {
    net_init();
    *pub_len = 0;
    *msg_len = 0;
    if (g_method != 0) upnp_unmap(g_mapped_port);

    char lan_ips[4][64];
    int n_ips = get_lan_ipv4s(lan_ips, 4);
    if (n_ips == 0) {
        write_slice(msg, msg_len, "No local network interface found");
        return -1;
    }

    char pub[64] = {0};
    int ok = 0;
    int saw_igd = 0;
    const char *via = "";
    char first_gw[64] = {0};

    for (int idx = 0; idx < n_ips && !ok; idx++) {
        const char *local_ip = lan_ips[idx];
        struct in_addr a;
        if (inet_pton(AF_INET, local_ip, &a) != 1) continue;
        uint32_t h = ntohl(a.s_addr);
        struct in_addr gw1, gw254;
        gw1.s_addr = htonl((h & 0xFFFFFF00u) | 1u);
        gw254.s_addr = htonl((h & 0xFFFFFF00u) | 254u);
        char gw1_str[64] = {0}, gw254_str[64] = {0};
        inet_ntop(AF_INET, &gw1, gw1_str, sizeof gw1_str);
        inet_ntop(AF_INET, &gw254, gw254_str, sizeof gw254_str);
        if (!first_gw[0]) snprintf(first_gw, sizeof first_gw, "%s", gw1_str);

        // 1) Try UPnP IGD (all unique SSDP responders on this LAN interface)
        char urls[16][256];
        int n_urls = upnp_discover_all(local_ip, gw1_str, urls, 16);
        for (int u = 0; u < n_urls && !ok; u++) {
            char chost[128], cpath[256], svc[128];
            int cport = 80;
            if (upnp_find_control(urls[u], chost, sizeof chost, &cport, cpath, sizeof cpath, svc, sizeof svc)) {
                saw_igd = 1;
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

        // 2) Fallback to NAT-PMP (v0) on .1 then .254
        if (!ok && natpmp_try_gw(local_ip, gw1_str, (int)port, pub, sizeof pub)) { ok = 1; via = "NAT-PMP"; }
        if (!ok && natpmp_try_gw(local_ip, gw254_str, (int)port, pub, sizeof pub)) { ok = 1; via = "NAT-PMP"; }

        // 3) Fallback to PCP (v2, RFC 6887) on .1 then .254
        if (!ok && pcp_try_gw(local_ip, gw1_str, (int)port, pub, sizeof pub)) { ok = 1; via = "PCP"; }
        if (!ok && pcp_try_gw(local_ip, gw254_str, (int)port, pub, sizeof pub)) { ok = 1; via = "PCP"; }
    }

    if (!ok) {
        char note[128];
        if (saw_igd) {
            snprintf(note, sizeof note, "Router %s UPnP rejected mapping - forward port manually or use playit.gg", first_gw);
        } else {
            snprintf(note, sizeof note, "No UPnP/NAT-PMP/PCP reply from %s (enable UPnP on router or use playit.gg)", first_gw);
        }
        write_slice(msg, msg_len, note);
        return -1;
    }

    if (pub[0] == 0) {
        char note[128];
        snprintf(note, sizeof note, "Mapped via %s (check whatismyip.com for public IP)", via);
        write_slice(msg, msg_len, note);
        return 0;
    }

    write_slice(pub_ip, pub_len, pub);
    if (is_private_or_cgnat(pub)) {
        char note[128];
        snprintf(note, sizeof note, "Mapped via %s, but ISP uses CGNAT/double-NAT (%s) - use playit.gg", via, pub);
        write_slice(msg, msg_len, note);
        return 1;
    }

    char note[128];
    snprintf(note, sizeof note, "Port %d open via %s", (int)port, via);
    write_slice(msg, msg_len, note);
    return 0;
}
