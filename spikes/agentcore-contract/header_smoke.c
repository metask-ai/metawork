#include "metacodes_agentcore.h"

#include <stddef.h>

int main(void) {
    const mc_agentcore_api_v1 *api =
        (const mc_agentcore_api_v1 *)metacodes_agentcore_get_api(MC_AGENTCORE_ABI_V1);
    if (api == NULL || api->struct_size != sizeof(*api) ||
        api->abi_version != MC_AGENTCORE_ABI_V1 ||
        (api->capabilities & (MC_CAP_RUNTIME | MC_CAP_BUILTIN_TOOLS |
                              MC_CAP_HOST_SYNC_TOOLS | MC_CAP_HOST_UI |
                              MC_CAP_CORE_EVENTS_JSON | MC_CAP_ABORT)) !=
            (MC_CAP_RUNTIME | MC_CAP_BUILTIN_TOOLS | MC_CAP_HOST_SYNC_TOOLS |
             MC_CAP_HOST_UI | MC_CAP_CORE_EVENTS_JSON | MC_CAP_ABORT) ||
        api->runtime_create == NULL || api->runtime_destroy == NULL ||
        api->session_create == NULL || api->session_destroy == NULL ||
        api->session_run == NULL || api->session_abort == NULL ||
        api->buffer_release == NULL) {
        return 1;
    }
    return metacodes_agentcore_get_api(MC_AGENTCORE_ABI_V1 + 1) == NULL ? 0 : 2;
}
