#include <metask/agentcore.h>

#include <stddef.h>

int main(void) {
    const metask_agentcore_api_v1 *api =
        (const metask_agentcore_api_v1 *)metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1);
    if (api == NULL || api->struct_size != sizeof(*api) ||
        api->abi_version != METASK_AGENTCORE_ABI_V1 ||
        api->abi_revision != METASK_AGENTCORE_ABI_REVISION ||
        (api->capabilities & METASK_AGENTCORE_REQUIRED_CAPABILITIES_V1) !=
            METASK_AGENTCORE_REQUIRED_CAPABILITIES_V1 ||
        api->runtime_create == NULL || api->runtime_destroy == NULL ||
        api->session_create == NULL || api->session_destroy == NULL ||
        api->session_run == NULL || api->session_abort == NULL ||
        api->buffer_release == NULL) {
        return 1;
    }
    return metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1 + 1) == NULL ? 0 : 2;
}
