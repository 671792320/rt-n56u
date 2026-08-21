from pathlib import Path
p = Path('trunk/user/camdiscover/camdiscover.c')
s = p.read_text()
if '#include <strings.h>' not in s:
    s = s.replace('#include <string.h>\n', '#include <string.h>\n#include <strings.h>\n', 1)
p.write_text(s)
