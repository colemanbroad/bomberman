// Minimal non-blocking UDP for the game: POSIX sockets on Mac/Linux, Winsock on Windows.
// Peers (IPv4 address + port) live in a small table here, so Goose only handles indexes.
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET sock_t;
#define BAD INVALID_SOCKET
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <unistd.h>
typedef int sock_t;
#define BAD (-1)
#endif

typedef struct { uint8_t *data; int64_t len; } bslice;

#define MAXPEERS 16
static struct sockaddr_in peers[MAXPEERS];
static int npeers = 0;

static int find_or_add(const struct sockaddr_in *a) {
    for (int i = 0; i < npeers; i++)
        if (peers[i].sin_addr.s_addr == a->sin_addr.s_addr && peers[i].sin_port == a->sin_port) return i;
    int i = npeers < MAXPEERS ? npeers++ : MAXPEERS - 1;
    peers[i] = *a;
    return i;
}

// A UDP socket bound to port (0: any), non-blocking. Returns a handle or -1.
int64_t udp_open(int64_t port) {
#ifdef _WIN32
    WSADATA w;
    WSAStartup(MAKEWORD(2, 2), &w);
#endif
    sock_t s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s == BAD) return -1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons((uint16_t)port);
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0) return -1;
#ifdef _WIN32
    u_long one = 1;
    ioctlsocket(s, FIONBIO, &one);
#else
    fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
#endif
    return (int64_t)s;
}

// Registers host:port (a name or dotted address) as a peer. Returns its index or -1.
int64_t udp_peer(bslice host, int64_t port) {
    char name[256];
    if (host.len <= 0 || host.len >= (int64_t)sizeof name) return -1;
    memcpy(name, host.data, (size_t)host.len);
    name[host.len] = 0;
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(name, NULL, &hints, &res) != 0 || !res) return -1;
    struct sockaddr_in a = *(struct sockaddr_in *)res->ai_addr;
    freeaddrinfo(res);
    a.sin_port = htons((uint16_t)port);
    return find_or_add(&a);
}

// Sends b to a peer. Returns the bytes sent or -1.
int64_t udp_send(int64_t fd, bslice b, int64_t peer) {
    if (peer < 0 || peer >= npeers) return -1;
    return (int64_t)sendto((sock_t)fd, (const char *)b.data, (int)b.len, 0, (struct sockaddr *)&peers[peer], sizeof peers[peer]);
}

// Receives one datagram into b. Returns its size, or -1 when none is waiting; *from gets the sender's peer index.
int64_t udp_recv(int64_t fd, bslice b, int64_t *from) {
    struct sockaddr_in a;
#ifdef _WIN32
    int n = (int)sizeof a;
#else
    socklen_t n = sizeof a;
#endif
    int64_t r = (int64_t)recvfrom((sock_t)fd, (char *)b.data, (int)b.len, 0, (struct sockaddr *)&a, &n);
    if (r < 0) return -1;
    *from = find_or_add(&a);
    return r;
}
