# State tests / 状态测试

These tests compile isolated production state logic with inert adapters. They do not pair computers, call models, or prove UI/device behavior.

这些测试在隔离环境中编译实际状态逻辑，使用无网络的替身；不配对电脑、不调用模型，也不代替界面与真机验收。

Run from the repository root on macOS with Xcode / 在安装 Xcode 的 macOS 上，从仓库根目录运行：

```sh
python3 scripts/tests/run-outbox-tests.py
python3 scripts/tests/run-host-activity-tests.py
python3 scripts/tests/run-session-pagination-tests.py
python3 scripts/tests/run-unread-tests.py
bash scripts/tests/run-sse-decoder-tests.sh
```

Other runners in this directory cover their named state modules. Check each runner's help and source for dependencies and options. Temporary build products are separate from app data. Some runners write local results under `docs/audit/`; those outputs are ignored by Git and must not be committed.

其他入口覆盖对应名称的状态模块，依赖和参数请查看各入口。部分测试会把本地结果写入 `docs/audit/`，该目录已被 Git 忽略；测试输出不得提交。
