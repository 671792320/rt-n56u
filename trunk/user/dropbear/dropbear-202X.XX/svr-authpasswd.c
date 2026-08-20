/*
 * Dropbear - a SSH2 server
 *
 * Password authentication backend for Q7 Padavan.
 *
 * The Q7 uClibc toolchain does not provide libcrypt. Padavan stores the
 * Web/administration password in NVRAM as http_passwd, so for this build we
 * authenticate directly against that value instead of calling crypt().
 */

#include "includes.h"
#include "session.h"
#include "buffer.h"
#include "dbutil.h"
#include "auth.h"
#include "runopts.h"

#if DROPBEAR_SVR_PASSWORD_AUTH

static int constant_time_strcmp(const char *a, const char *b) {
	size_t la = strlen(a);
	size_t lb = strlen(b);
	if (la != lb) {
		return 1;
	}
	return constant_time_memcmp(a, b, la);
}

static int q7_nvram_get(const char *name, char *out, size_t outlen) {
	FILE *fp;
	char cmd[64];
	char *p;

	if (!out || outlen < 2) {
		return -1;
	}
	out[0] = '\0';

	/* Fixed command/argument: no user-controlled shell input. */
	snprintf(cmd, sizeof(cmd), "/usr/sbin/nvram get %s", name);
	fp = popen(cmd, "r");
	if (!fp) {
		/* Some Padavan builds install nvram under /usr/bin. */
		fp = popen("/usr/bin/nvram get http_passwd", "r");
	}
	if (!fp) {
		return -1;
	}

	if (!fgets(out, (int)outlen, fp)) {
		pclose(fp);
		out[0] = '\0';
		return -1;
	}
	pclose(fp);

	p = strpbrk(out, "\r\n");
	if (p) {
		*p = '\0';
	}
	return out[0] ? 0 : -1;
}

void svr_auth_password(int valid_user) {
	char *password = NULL;
	unsigned int passwordlen;
	unsigned int changepw;
	char nvram_pass[128];

	changepw = buf_getbool(ses.payload);
	if (changepw) {
		send_msg_userauth_failure(0, 1);
		return;
	}

	password = buf_getstring(ses.payload, &passwordlen);

	if (!valid_user) {
		m_burn(password, passwordlen);
		m_free(password);
		send_msg_userauth_failure(0, 1);
		return;
	}

	if (passwordlen > DROPBEAR_MAX_PASSWORD_LEN) {
		dropbear_log(LOG_WARNING, "Too-long password attempt for '%s' from %s",
				ses.authstate.pw_name, svr_ses.addrstring);
		m_burn(password, passwordlen);
		m_free(password);
		send_msg_userauth_failure(0, 1);
		return;
	}

	if (q7_nvram_get("http_passwd", nvram_pass, sizeof(nvram_pass)) < 0) {
		dropbear_log(LOG_WARNING, "Unable to read Padavan http_passwd for '%s'",
				ses.authstate.pw_name);
		m_burn(password, passwordlen);
		m_free(password);
		send_msg_userauth_failure(0, 1);
		return;
	}

	if (constant_time_strcmp(password, nvram_pass) == 0) {
		dropbear_log(LOG_NOTICE, "Password auth succeeded for '%s' from %s",
				ses.authstate.pw_name, svr_ses.addrstring);
		send_msg_userauth_success();
	} else {
		dropbear_log(LOG_WARNING, "Bad password attempt for '%s' from %s",
				ses.authstate.pw_name, svr_ses.addrstring);
		send_msg_userauth_failure(0, 1);
	}

	m_burn(password, passwordlen);
	m_free(password);
}

#endif
