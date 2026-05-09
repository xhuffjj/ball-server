// simple lua socket library for client
// It's only for demo, limited feature. Don't use it in your project.
// Rewrite socket library by yourself .

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#define LUA_LIB

#include <lua.h>
#include <lauxlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include <stdlib.h>

#include <netinet/in.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>

#if defined(__APPLE__) || defined(__linux__) || defined(__unix__)
#include <sys/time.h>
#endif

#define CACHE_SIZE 0x1000	

static void
fill_addr(struct sockaddr_in *addr, const char *host, int port) {
	memset(addr, 0, sizeof(*addr));
	addr->sin_addr.s_addr = inet_addr(host);
	addr->sin_family = AF_INET;
	addr->sin_port = htons(port);
}

static void
set_nonblock(lua_State *L, int fd) {
	int flag = fcntl(fd, F_GETFL, 0);
	if (flag < 0) {
		close(fd);
		luaL_error(L, "socket error: %s", strerror(errno));
	}
	if (fcntl(fd, F_SETFL, flag | O_NONBLOCK) < 0) {
		close(fd);
		luaL_error(L, "socket error: %s", strerror(errno));
	}
}

static int
connect_inet(lua_State *L, int socket_type, const char * opname) {
	const char * addr = luaL_checkstring(L, 1);
	int port = luaL_checkinteger(L, 2);
	int fd = socket(AF_INET, socket_type, 0);
	struct sockaddr_in my_addr;

	if (fd < 0) {
		return luaL_error(L, "%s %s %d failed: %s", opname, addr, port, strerror(errno));
	}

	fill_addr(&my_addr, addr, port);

	if (connect(fd, (struct sockaddr *)&my_addr, sizeof(my_addr)) == -1) {
		int err = errno;
		close(fd);
		return luaL_error(L, "%s %s %d failed: %s", opname, addr, port, strerror(err));
	}

	set_nonblock(L, fd);
	lua_pushinteger(L, fd);
	return 1;
}

static int
lconnect(lua_State *L) {
	return connect_inet(L, SOCK_STREAM, "Connect");
}

static int
ludp(lua_State *L) {
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		return luaL_error(L, "Create UDP socket failed: %s", strerror(errno));
	}

	if (lua_gettop(L) >= 2) {
		const char * addr = luaL_checkstring(L, 1);
		int port = luaL_checkinteger(L, 2);
		struct sockaddr_in my_addr;
		fill_addr(&my_addr, addr, port);
		if (bind(fd, (struct sockaddr *)&my_addr, sizeof(my_addr)) == -1) {
			int err = errno;
			close(fd);
			return luaL_error(L, "Bind UDP %s %d failed: %s", addr, port, strerror(err));
		}
	}

	set_nonblock(L, fd);
	lua_pushinteger(L, fd);
	return 1;
}

static int
ludp_connect(lua_State *L) {
	return connect_inet(L, SOCK_DGRAM, "UDP connect");
}

static int
lclose(lua_State *L) {
	int fd = luaL_checkinteger(L, 1);
	close(fd);

	return 0;
}

static void
block_send(lua_State *L, int fd, const char * buffer, int sz) {
	while(sz > 0) {
		int r = send(fd, buffer, sz, 0);
		if (r < 0) {
			if (errno == EAGAIN || errno == EINTR)
				continue;
			luaL_error(L, "socket error: %s", strerror(errno));
		}
		buffer += r;
		sz -= r;
	}
}

/*
	integer fd
	string message
 */
static int
lsend(lua_State *L) {
	size_t sz = 0;
	int fd = luaL_checkinteger(L,1);
	const char * msg = luaL_checklstring(L, 2, &sz);

	block_send(L, fd, msg, (int)sz);

	return 0;
}

static int
lsendto(lua_State *L) {
	size_t sz = 0;
	int fd = luaL_checkinteger(L, 1);
	const char * addr = luaL_checkstring(L, 2);
	int port = luaL_checkinteger(L, 3);
	const char * msg = luaL_checklstring(L, 4, &sz);
	struct sockaddr_in to_addr;

	fill_addr(&to_addr, addr, port);
	while (1) {
		int r = sendto(fd, msg, sz, 0, (struct sockaddr *)&to_addr, sizeof(to_addr));
		if (r < 0) {
			if (errno == EAGAIN || errno == EINTR)
				continue;
			luaL_error(L, "socket error: %s", strerror(errno));
		}
		break;
	}

	return 0;
}

/*
	intger fd
	string last
	table result

	return 
		boolean (true: data, false: block, nil: close)
		string last
 */

struct socket_buffer {
	void * buffer;
	int sz;
};

static int
lrecv(lua_State *L) {
	int fd = luaL_checkinteger(L,1);

	char buffer[CACHE_SIZE];
	int r = recv(fd, buffer, CACHE_SIZE, 0);
	if (r == 0) {
		lua_pushliteral(L, "");
		// close
		return 1;
	}
	if (r < 0) {
		if (errno == EAGAIN || errno == EINTR) {
			return 0;
		}
		luaL_error(L, "socket error: %s", strerror(errno));
	}
	lua_pushlstring(L, buffer, r);
	return 1;
}

static int
lrecvfrom(lua_State *L) {
	int fd = luaL_checkinteger(L,1);
	char buffer[CACHE_SIZE];
	struct sockaddr_in from_addr;
	socklen_t addrlen = sizeof(from_addr);
	int r = recvfrom(fd, buffer, CACHE_SIZE, 0, (struct sockaddr *)&from_addr, &addrlen);
	if (r < 0) {
		if (errno == EAGAIN || errno == EINTR) {
			return 0;
		}
		luaL_error(L, "socket error: %s", strerror(errno));
	}
	lua_pushlstring(L, buffer, r);
	lua_pushstring(L, inet_ntoa(from_addr.sin_addr));
	lua_pushinteger(L, ntohs(from_addr.sin_port));
	return 3;
}

static int
lusleep(lua_State *L) {
	lua_Integer n = luaL_checkinteger(L, 1);
	struct timespec req;
	req.tv_sec = n / 1000000;
	req.tv_nsec = (n % 1000000) * 1000;
	nanosleep(&req, NULL);
	return 0;
}

static int
ltime_ms(lua_State *L) {
#if defined(CLOCK_MONOTONIC)
	struct timespec ti;
	clock_gettime(CLOCK_MONOTONIC, &ti);
	lua_pushinteger(L, (lua_Integer)ti.tv_sec * 1000 + ti.tv_nsec / 1000000);
#elif defined(__APPLE__) || defined(__linux__) || defined(__unix__)
	struct timeval tv;
	gettimeofday(&tv, NULL);
	lua_pushinteger(L, (lua_Integer)tv.tv_sec * 1000 + tv.tv_usec / 1000);
#else
	lua_pushinteger(L, (lua_Integer)time(NULL) * 1000);
#endif
	return 1;
}

// quick and dirty none block stdin readline

#define QUEUE_SIZE 1024

struct queue {
	pthread_mutex_t lock;
	int head;
	int tail;
	char * queue[QUEUE_SIZE];
};

static void *
readline_stdin(void * arg) {
	struct queue * q = arg;
	char tmp[1024];
	while (!feof(stdin)) {
		if (fgets(tmp,sizeof(tmp),stdin) == NULL) {
			// read stdin failed
			exit(1);
		}
		int n = strlen(tmp) -1;

		char * str = malloc(n+1);
		memcpy(str, tmp, n);
		str[n] = 0;

		pthread_mutex_lock(&q->lock);
		q->queue[q->tail] = str;

		if (++q->tail >= QUEUE_SIZE) {
			q->tail = 0;
		}
		if (q->head == q->tail) {
			// queue overflow
			exit(1);
		}
		pthread_mutex_unlock(&q->lock);
	}
	return NULL;
}

static int
lreadstdin(lua_State *L) {
	struct queue *q = lua_touserdata(L, lua_upvalueindex(1));
	pthread_mutex_lock(&q->lock);
	if (q->head == q->tail) {
		pthread_mutex_unlock(&q->lock);
		return 0;
	}
	char * str = q->queue[q->head];
	if (++q->head >= QUEUE_SIZE) {
		q->head = 0;
	}
	pthread_mutex_unlock(&q->lock);
	lua_pushstring(L, str);
	free(str);
	return 1;
}

static int
lshutdown(lua_State *L) {
	int fd = luaL_checkinteger(L,1);
	const char *mode = luaL_checkstring(L,2);
	int v = 0;
	int i;
	int read = 1;
	int write = 2;
	for (i=0;mode[i];i++) {
		switch(mode[i]) {
		case 'r':
			v |= read;
			break;
		case 'w':
			v |= write;
			break;
		default:
			return luaL_error(L, "Invalid mode %c", mode[i]);
		}
	}
	if (v == 0) {
		return luaL_error(L, "mode should be r or/and w");
	}
	if (v == read)
		v = SHUT_RD;
	else if (v == write)
		v = SHUT_WR;
	else
		v = SHUT_RDWR;
	printf("SHUTDOWN %d %d\n", fd, v);
	shutdown(fd, v);
	return 0;
}

LUAMOD_API int
luaopen_client_socket(lua_State *L) {
	luaL_checkversion(L);
	luaL_Reg l[] = {
		{ "connect", lconnect },
		{ "udp", ludp },
		{ "udp_connect", ludp_connect },
		{ "recv", lrecv },
		{ "recvfrom", lrecvfrom },
		{ "send", lsend },
		{ "sendto", lsendto },
		{ "shutdown", lshutdown },
		{ "close", lclose },
		{ "time_ms", ltime_ms },
		{ "usleep", lusleep },
		{ NULL, NULL },
	};
	luaL_newlib(L, l);

	struct queue * q = lua_newuserdata(L, sizeof(*q));
	memset(q, 0, sizeof(*q));
	pthread_mutex_init(&q->lock, NULL);
	lua_pushcclosure(L, lreadstdin, 1);
	lua_setfield(L, -2, "readstdin");

	pthread_t pid ;
	pthread_create(&pid, NULL, readline_stdin, q);

	return 1;
}
