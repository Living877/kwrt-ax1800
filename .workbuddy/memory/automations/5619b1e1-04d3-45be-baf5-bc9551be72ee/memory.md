# 自动化记忆：检查 AX1800 Pro 固件编译状态

## 执行记录

### 2026-10-29 13:42 (UTC+8)
- 最新 run：#11（commit e651055，run_id 40824419004），状态 in_progress，开始 05:36:57Z。
- 进度：probe job 成功；build job 进行到 13 步中的第 8 步「生成配置」（05:42:35Z 起），后续「编译前校验 / 编译 / 复核内核体积 / 上传产物 / 发布 Release」均 pending。
- 历史：#10（a046541）failure，#9（224b03f）failure。
- 结论：仍在正常编译早期阶段，未出结果，无需深度排查。

### 2026-10-29 14:54 (UTC+8)
- 最新 run 仍是 #11（e651055，run_id 40824419004），status in_progress，无更新 run。
- 关键进展：第 9 步「编译前校验」已通过（05:43:46Z 结束，耗时 0 秒级说明自检直接过），此前 #7–#10 连续 4 次卡死在此步——iStore Kconfig 修复（关 TAR_XZ + 显式点开 luci-lua-runtime/luci-lib-taskd/mount-utils）确认有效。
- 当前：build job 第 10 步「编译」进行中（05:43:46Z 起，已约 70 分钟），后续 11–13 步 pending。
- 结论：属正常编译时长区间，未出结果；下次继续轮询即可。

### 2026-10-29 15:55 (UTC+8)
- 最新 run 仍是 #11（e651055，run_id 40824419004），status in_progress，无更新 run。
- 进度：build job 第 10 步「编译」自 05:43:46Z 起持续进行，已约 2 小时 11 分；步骤 11–13（复核内核体积 / 上传产物 / 发布 Release）pending。
- 结论：处于 2–3 小时正常区间后段，仍未出结果。下次轮询若仍卡在同一 started_at 需警惕静默挂起。

### 2026-10-29 16:55 (UTC+8)
- 最新 run 仍是 #11（e651055，run_id 40824419004），status in_progress，无更新 run。
- 进度：build job 第 10 步「编译」自 05:43:46Z 起，已约 3 小时 12 分，超出 2–3 小时正常区间；步骤 11–14 pending。
- 已向用户提示超时风险（可能静默挂起），建议下次轮询仍无变化则考虑取消重跑。

## 备注
- 本机取 token 用 `git credential fill`（host=github.com），只放请求头。
- Windows python 读不到 Git Bash 的 /tmp，临时文件一律写到 C:/Users/31936/WorkBuddy/2026-10-28-21-17-02/ 下。

### 2026-10-29 17:57 (UTC+8)
- 最新 run 仍是 #11（e651055，run_id 40824419004），status in_progress，无更新 run。
- 进度无变化：build job 第 10 步「编译」自 05:43:46Z 起持续，已约 4 小时 14 分；步骤 11–14 仍 pending。
- 构建 job 的 timeout-minutes=350（5h50m），硬超时点约 11:27Z / 19:27 CST，剩余约 1.5 小时。
- job 日志端点在 in_progress 期间返回 404，无法看实时进度；releases/latest 仍 404（未发布过）。
- 结论：已明显超出 2–3 小时正常区间且长时间无 step 状态变化，判定为疑似静默挂起；建议用户取消并按同一 commit 重跑。

### 2026-10-29 18:00 (UTC+8) — 修正判断
- 用户提供了实时构建日志片段：run #11 实际仍在正常编译，**不是静默挂起**，撤回 17:57 的挂起判断。
- 日志显示 tools/compile、toolchain/compile、target/linux compile 已完成，当前在 package/compile 尾段（已到 luci-app-store / luci-app-diskman / luci-nginx / luci-app-samba4）。
- `feeds/kiddin9/luci-app-store compile` 出现在编译列表 → iStore 确实被编译，CONFIG_PACKAGE_luci-app-store=y 生效，iStore Kconfig 修复有效。
- 经验：GitHub 的 step 状态在「编译」这一步长达数小时不变是正常的（内部 make world 进度不反映到 API）；以后不能只看 started_at 判定挂起，需结合用户侧实时日志。这套 kiddin9 全家桶含 rust/node/golang/samba4，4–5 小时属合理区间；硬超时 350 分钟。

### 2026-10-29 19:00 (UTC+8) — run #11 结束
- run #11（e651055，40824419004）completed / **failure**，build job 05:37Z→10:30Z（4h53m）。
- 步骤 1–12 全绿：编译前校验 ✅、编译 ✅、复核内核体积 ✅、上传产物 ✅；仅第 13 步「发布 Release」失败。
- 内核 FIT 4.673 MiB / 6 MiB（余量 1359 KiB）；`[+] 6MiB 处 hsqs 校验通过`（A2 断言跑到且通过）。
- 失败根因：`gh release create` 在 openwrt/ 子目录执行，gh 按 git remote 推断仓库 → 向上游 openwrt/openwrt 建 release → `HTTP 403 Resource not accessible by integration`。修法：加 `-R "$GITHUB_REPOSITORY"`（或先 cd $GITHUB_WORKSPACE）。非依赖/补丁/defconfig/编译问题。
- 仓库无任何 Release（releases 列表为空）。产物 artifact `kwrt-ax1800-11` 147.5 MiB / 30 天；内含 4 个 `*jdcloud_re-ss-01*` 原始名文件 + .config，**固定名 sysupgrade.bin / factory.bin 未生成**（在发布步骤里才 cp）。
- 未改动仓库，等用户确认后再改 build.yml。
- 经验：gh CLI 在子仓库目录下会错误推断目标仓库，凡 cd 进 openwrt/ 后的 gh 命令都要显式 -R。
