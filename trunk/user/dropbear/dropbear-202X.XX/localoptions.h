#ifndef DROPBEAR_LOCALOPTIONS_H_
#define DROPBEAR_LOCALOPTIONS_H_

/* Q7 first-build compatibility: this uClibc toolchain has no crypt().
 * Keep public-key authentication enabled; password authentication can be
 * restored later if libcrypt is added to the firmware toolchain. */
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#define DROPBEAR_SVR_PUBKEY_AUTH 1

#include "default_options.h"

#endif /* DROPBEAR_LOCALOPTIONS_H_ */
