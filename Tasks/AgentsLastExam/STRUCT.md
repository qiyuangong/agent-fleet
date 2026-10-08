# ALE Harbor adapter boundaries

| File | Responsibility |
| --- | --- |
| `setup.sh`, `run.sh` | Shared configuration and process entrypoints |
| `ale_adapter/prepare.py` | Explicit native source/dependency installation |
| `ale_adapter/source.py` | Revision, source integrity and image-map checks |
| `ale_adapter/adapter.py` | Native variant discovery and Windows task conversion |
| `ale_adapter/launch.py` | Validate prepared dataset; replace process with Harbor CLI |
| `ale_adapter/environment.py` | Per-trial PVC/GPU selection and native phase subprocess ownership |
| `ale_adapter/native.py` | Native ALE session, staging, task setup/evaluation |
| `ale_adapter/verifier.py` | Native score validation and Harbor rewards |

Agent execution reuses `kubevirt_windows.agent:WindowsCommandAgent`, or a custom
Windows Harbor agent. Native dependencies run outside the Harbor interpreter.
Grading remains in the unchanged ALE source; no alternate job scheduler,
reporting pipeline or resume implementation belongs here.
