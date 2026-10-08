# ALE Harbor adapter boundaries

| File | Responsibility |
| --- | --- |
| `setup.sh`, `run.sh` | Shared configuration and process entrypoints |
| `ale_adapter/prepare.py` | Explicit native source/dependency installation |
| `ale_adapter/source.py` | Revision, source integrity and image-map checks |
| `ale_adapter/adapter.py` | Native Linux/Windows CPU variant discovery and conversion; exclude GPU before imports |
| `ale_adapter/launch.py` | Validate prepared dataset; replace process with Harbor CLI |
| `ale_adapter/environment.py` | Harbor guest I/O, Windows PVC delegation and native worker ownership |
| `ale_adapter/linux_worker.py` | Native QEMU lifecycle and Linux command/file RPC in the separate native interpreter |
| `ale_adapter/native.py` | Unchanged ALE driver/session, staging and setup/evaluation |
| `ale_adapter/verifier.py` | Native score validation and Harbor rewards |
| `../../Agents/AgentsLastExam/agent.py` | Mixed-OS image-provided command agent; Windows delegates to the existing bridge |

Custom Harbor agents can replace the default command agent. Native dependencies
run outside the Harbor interpreter. Grading remains in unchanged ALE source;
no alternate scheduler, reporting or resume implementation belongs here.
