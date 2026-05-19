/*
 * pager.app launcher — Mach-O binary version.
 *
 * Exec's the real pager binary at $PAGER_ROOT/bin/pager. Passes through
 * all arguments unchanged.
 *
 * Why a binary instead of a shell script:
 *   macOS Tahoe (and likely later Sonoma builds) appear to reject icon
 *   rendering for .app bundles whose Contents/MacOS/<executable> is a
 *   shell script with a #!/bin/sh shebang. Quick Look hangs on such
 *   bundles even when the AppIcon.icns is individually valid. Login
 *   Items shows the generic exec icon and the bundle never gets the
 *   custom one. Replacing the launcher with a tiny C binary (a real
 *   Mach-O executable) is what unblocks icon resolution.
 *
 * Build:
 *   clang -arch arm64 -arch x86_64 -O2 -mmacosx-version-min=11.0 \
 *     -o pager pager.c
 *
 * Done automatically by macos/bootstrap.sh during install.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    const char *pager_root = getenv("PAGER_ROOT");
    char path[2048];

    if (pager_root != NULL && pager_root[0] != '\0') {
        snprintf(path, sizeof(path), "%s/bin/pager", pager_root);
    } else {
        /* Fallback: $HOME/.pager/bin/pager (default install location). */
        const char *home = getenv("HOME");
        if (home == NULL) {
            fprintf(stderr, "pager.app launcher: PAGER_ROOT and HOME both unset\n");
            return 1;
        }
        snprintf(path, sizeof(path), "%s/.pager/bin/pager", home);
    }

    /* Replace this process with the real pager binary.
     * argv[0] becomes the path; argv[1..] pass through unchanged. */
    argv[0] = path;
    execv(path, argv);

    /* execv only returns on error. */
    fprintf(stderr, "pager.app launcher: exec failed: %s\n", path);
    return 1;
}
