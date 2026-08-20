/*
 * Dropbear SSH
 * Copyright (c) 2002,2003 Matt Johnston
 */
#ifndef DROPBEAR_COMPAT_H_
#define DROPBEAR_COMPAT_H_
#include "includes.h"
#ifndef HAVE_STRLCPY
size_t strlcpy(char *dst, const char *src, size_t size);
#endif
#ifndef HAVE_STRLCAT
size_t strlcat(char *dst, const char *src, size_t siz);
#endif
#ifndef HAVE_DAEMON
int daemon(int nochdir, int noclose);
#endif
/* The uClibc sysroot already provides basename() through libgen.h.
 * Force the configure result for this cross-build so the compatibility
 * declaration is not emitted with an incompatible prototype. */
#ifndef HAVE_BASENAME
#define HAVE_BASENAME 1
#endif
#ifndef DROPBEAR_PATH_DEVNULL
#define DROPBEAR_PATH_DEVNULL "/dev/null"
#endif
#endif /* DROPBEAR_COMPAT_H_ */
