// A shim, not Luanti's: see README.txt.
#include "log.h"

namespace luanti_shim_log {

LogStream errorstream_(0);
LogStream warningstream_(1);
LogStream actionstream_(2);
LogStream infostream_(2);
LogStream verbosestream_(3);
LogStream dstream_(3);

}
