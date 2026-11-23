# 口令覆盖率基线（local / model / none）

> 本文件由测试生成，请勿手工编辑。
> 语料 `Tests/Fixtures/intent_coverage_corpus.json`：251 条中文口令，19 类，12 台设备的固定虚构家庭。
> 重录：`RECORD_INTENT_COVERAGE=1 swift test --filter IntentCoverageBaseline`
> 生成时间：2026-11-23T15:32:07Z

## 口径

按 `HomeStore.runAssistantCommand` 的阶段顺序判：定时取消 → 语音撤销 → 口语延后（“10分钟后”）→ `LocalIntentParser` → 模型。

- **local**：`LocalIntentParser` 给出了指令（已剥掉口语延后前缀）。零网络、可复现。
- **model**：本地解析器拒答，助手会把这句话交给大模型；成功率取决于模型，不在这张表里。表里不分原因：句式没覆盖、设备不支持该参数、目标有歧义，都会落到这一格。
- **none**：本地无解，而且在流水线里也不会发模型请求——句子被更早的专门阶段接走了（「取消定时」「撤销」）。

只跑不判：表里没有“期望值”，也还没有对错。这些数字是基线，不是门槛。
面板房间（`panelRoom`）留空，所以“打开灯”这类裸类别句按全屋判定。

## 汇总

| 类别 | local | model | none | 合计 | local 占比 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `power_on` | 18 | 0 | 0 | 18 | 100.0% |
| `power_off` | 16 | 0 | 0 | 16 | 100.0% |
| `scope_power` | 11 | 3 | 0 | 14 | 78.6% |
| `brightness` | 12 | 4 | 0 | 16 | 75.0% |
| `brightness_step` | 12 | 0 | 0 | 12 | 100.0% |
| `color_temperature` | 9 | 5 | 0 | 14 | 64.3% |
| `light_effect` | 4 | 4 | 0 | 8 | 50.0% |
| `climate_temperature` | 13 | 3 | 0 | 16 | 81.3% |
| `climate_step` | 9 | 1 | 0 | 10 | 90.0% |
| `climate_mode` | 9 | 3 | 0 | 12 | 75.0% |
| `fan_speed` | 10 | 4 | 0 | 14 | 71.4% |
| `fan_percentage` | 8 | 2 | 0 | 10 | 80.0% |
| `oscillation` | 8 | 0 | 0 | 8 | 100.0% |
| `cover` | 0 | 12 | 0 | 12 | 0.0% |
| `scene` | 11 | 1 | 0 | 12 | 91.7% |
| `state_query` | 0 | 16 | 0 | 16 | 0.0% |
| `timer` | 11 | 2 | 3 | 16 | 68.8% |
| `polite_form` | 2 | 10 | 0 | 12 | 16.7% |
| `out_of_domain` | 0 | 15 | 0 | 15 | 0.0% |
| **合计** | **163** | **85** | **3** | **251** | **64.9%** |

## 固定家庭

| 设备 | 房间 | 类型 |
| --- | --- | --- |
| 书房吸顶灯 | 书房 | `light` |
| 书房台灯 | 书房 | `light` |
| 书房插座 | 书房 | `plug` |
| 客厅主灯 | 客厅 | `light` |
| 客厅落地灯 | 客厅 | `light` |
| 客厅空调 | 客厅 | `climate` |
| 客厅风扇 | 客厅 | `fan` |
| 客厅窗帘 | 客厅 | `cover` |
| 主卧床头灯 | 主卧 | `light` |
| 主卧空气净化器 | 主卧 | `airPurifier` |
| 卫生间暖风机 | 卫生间 | `heater` |
| 玄关扫地机器人 | 玄关 | `vacuum` |
| 回家模式 / 观影模式 / 睡眠模式 | — | 场景 |


## 逐句去向

| 类别 | 口令 | 去向 |
| --- | --- | --- |
| `power_on` | 打开书房吸顶灯 | local |
| `power_on` | 把书房台灯打开 | local |
| `power_on` | 开一下客厅落地灯 | local |
| `power_on` | 打开主卧床头灯 | local |
| `power_on` | 请帮我打开客厅主灯 | local |
| `power_on` | 开启书房台灯 | local |
| `power_on` | 把书房的灯打开 | local |
| `power_on` | 打开书房灯 | local |
| `power_on` | 书房吸顶灯打开 | local |
| `power_on` | 打开书房插座 | local |
| `power_on` | 打开客厅空调 | local |
| `power_on` | 打开客厅风扇 | local |
| `power_on` | 打开主卧空气净化器 | local |
| `power_on` | 打开玄关扫地机器人 | local |
| `power_on` | 开卫生间暖风机 | local |
| `power_on` | 把台灯打开 | local |
| `power_on` | 帮我把客厅灯开了 | local |
| `power_on` | 打开灯 | local |
| `power_off` | 关闭书房吸顶灯 | local |
| `power_off` | 把客厅空调关掉 | local |
| `power_off` | 关掉书房台灯 | local |
| `power_off` | 关上主卧床头灯 | local |
| `power_off` | 关客厅主灯 | local |
| `power_off` | 熄灭客厅落地灯 | local |
| `power_off` | 关闭书房插座 | local |
| `power_off` | 把风扇关了 | local |
| `power_off` | 关一下空气净化器 | local |
| `power_off` | 客厅空调关掉 | local |
| `power_off` | 帮我把书房的灯关了 | local |
| `power_off` | 关闭玄关扫地机器人 | local |
| `power_off` | 客厅落地灯关掉 | local |
| `power_off` | 关掉客厅的灯 | local |
| `power_off` | 主卧床头灯熄灭 | local |
| `power_off` | 关灯 | local |
| `scope_power` | 打开全部灯 | local |
| `scope_power` | 打开所有灯 | local |
| `scope_power` | 打开全屋的灯 | local |
| `scope_power` | 全屋关灯 | local |
| `scope_power` | 关闭全部灯 | local |
| `scope_power` | 关所有灯 | local |
| `scope_power` | 打开全部设备 | model |
| `scope_power` | 关掉所有设备 | local |
| `scope_power` | 全屋设备关掉 | local |
| `scope_power` | 家里全部灯打开 | local |
| `scope_power` | 关闭全家设备 | model |
| `scope_power` | 把家里所有灯关掉 | local |
| `scope_power` | 全部关掉 | local |
| `scope_power` | 全部打开 | model |
| `brightness` | 书房吸顶灯亮度调到50% | local |
| `brightness` | 把书房台灯亮度设为20 | local |
| `brightness` | 客厅落地灯调到80% | local |
| `brightness` | 书房吸顶灯调到30% | local |
| `brightness` | 把主卧床头灯亮度调到70 | local |
| `brightness` | 客厅主灯调到100% | local |
| `brightness` | 客厅主灯调到最亮 | local |
| `brightness` | 书房台灯最暗 | local |
| `brightness` | 台灯调暗 | local |
| `brightness` | 台灯调亮 | local |
| `brightness` | 把主卧床头灯调亮 | local |
| `brightness` | 书房灯亮度调到百分之六十 | model |
| `brightness` | 亮度调到100% | model |
| `brightness` | 把客厅落地灯的亮度调低 | model |
| `brightness` | 书房吸顶灯亮度百分之四十 | model |
| `brightness` | 灯调暗一点 | local |
| `brightness_step` | 暗一点 | local |
| `brightness_step` | 亮一点 | local |
| `brightness_step` | 再暗一些 | local |
| `brightness_step` | 书房吸顶灯暗一点 | local |
| `brightness_step` | 把书房台灯调暗一点 | local |
| `brightness_step` | 客厅落地灯亮一些 | local |
| `brightness_step` | 台灯再亮一点 | local |
| `brightness_step` | 全屋灯暗一点 | local |
| `brightness_step` | 都暗一点 | local |
| `brightness_step` | 书房灯亮一点 | local |
| `brightness_step` | 主卧床头灯暗一点 | local |
| `brightness_step` | 把客厅灯调亮一点 | local |
| `color_temperature` | 把书房吸顶灯调成暖光 | local |
| `color_temperature` | 书房台灯调到冷白 | local |
| `color_temperature` | 客厅落地灯设成暖白 | local |
| `color_temperature` | 书房吸顶灯色温调到2700K | local |
| `color_temperature` | 把灯光调成烛光 | model |
| `color_temperature` | 书房灯调成自然光 | local |
| `color_temperature` | 客厅主灯调到白光 | local |
| `color_temperature` | 台灯调成日光 | local |
| `color_temperature` | 书房吸顶灯色温调到4000k | local |
| `color_temperature` | 书房灯调成冷光 | local |
| `color_temperature` | 客厅落地灯调到暖黄光 | model |
| `color_temperature` | 把书房台灯的色温调暖 | model |
| `color_temperature` | 灯光调黄一点 | model |
| `color_temperature` | 书房灯调成中性光 | model |
| `light_effect` | 书房吸顶灯月光模式 | local |
| `light_effect` | 书房吸顶灯打开月光 | local |
| `light_effect` | 书房台灯夜灯模式 | model |
| `light_effect` | 开启书房吸顶灯的夜灯 | model |
| `light_effect` | 书房吸顶灯切换到日光模式 | local |
| `light_effect` | 客厅落地灯月光模式 | local |
| `light_effect` | 把书房吸顶灯调到夜灯模式 | model |
| `light_effect` | 书房吸顶灯白天模式 | model |
| `climate_temperature` | 客厅空调调到26度 | local |
| `climate_temperature` | 把客厅空调设为24度 | local |
| `climate_temperature` | 空调调到26℃ | local |
| `climate_temperature` | 客厅空调温度调到22.5度 | local |
| `climate_temperature` | 卫生间暖风机调到25度 | local |
| `climate_temperature` | 空调调到22 | model |
| `climate_temperature` | 空调温度26度 | local |
| `climate_temperature` | 把空调温度设为26度 | local |
| `climate_temperature` | 空调调到16度 | local |
| `climate_temperature` | 客厅空调调成制冷26度 | local |
| `climate_temperature` | 客厅空调温度调到26 | model |
| `climate_temperature` | 空调调到二十六度 | model |
| `climate_temperature` | 暖风机温度24度 | local |
| `climate_temperature` | 把空调的温度调成25度 | local |
| `climate_temperature` | 客厅空调26度 | local |
| `climate_temperature` | 空调28度 | local |
| `climate_step` | 客厅空调调高两度 | local |
| `climate_step` | 空调调低一度 | local |
| `climate_step` | 把客厅空调温度调高2度 | local |
| `climate_step` | 客厅空调温度低一点 | local |
| `climate_step` | 空调热一点 | local |
| `climate_step` | 卫生间暖风机温度高一些 | local |
| `climate_step` | 空调调低1度 | local |
| `climate_step` | 客厅空调冷一点 | local |
| `climate_step` | 把空调调高3度 | local |
| `climate_step` | 暖风机温度降低两度 | model |
| `climate_mode` | 客厅空调制冷 | local |
| `climate_mode` | 空调制热 | local |
| `climate_mode` | 把客厅空调调到除湿模式 | local |
| `climate_mode` | 客厅空调送风 | local |
| `climate_mode` | 空调自动模式 | model |
| `climate_mode` | 客厅空调切到制热 | local |
| `climate_mode` | 空调调到睡眠模式 | model |
| `climate_mode` | 卫生间暖风机打开制热 | local |
| `climate_mode` | 空调开制冷 | local |
| `climate_mode` | 把空调切成除湿 | local |
| `climate_mode` | 客厅空调模式改成送风 | local |
| `climate_mode` | 空调调到酷冷模式 | model |
| `fan_speed` | 客厅风扇高档 | local |
| `fan_speed` | 风扇中档 | local |
| `fan_speed` | 把风扇调到低速 | local |
| `fan_speed` | 客厅风扇睡眠模式 | model |
| `fan_speed` | 风扇自动风 | model |
| `fan_speed` | 风扇一档 | local |
| `fan_speed` | 客厅风扇三档 | local |
| `fan_speed` | 风扇最大风 | local |
| `fan_speed` | 风扇小风 | local |
| `fan_speed` | 客厅风扇静音模式 | model |
| `fan_speed` | 风扇最爱模式 | model |
| `fan_speed` | 风扇中速 | local |
| `fan_speed` | 空调风速调高 | local |
| `fan_speed` | 把客厅风扇调到二档 | local |
| `fan_percentage` | 客厅风扇风速调到50% | local |
| `fan_percentage` | 风扇风速设为30 | model |
| `fan_percentage` | 把客厅风扇调到百分之七十 | local |
| `fan_percentage` | 风扇百分之五十 | local |
| `fan_percentage` | 客厅风扇风速百分之百 | local |
| `fan_percentage` | 风速调到20% | local |
| `fan_percentage` | 客厅风扇风速调到10% | local |
| `fan_percentage` | 风扇风速调到100% | local |
| `fan_percentage` | 把风扇风速调低一点 | local |
| `fan_percentage` | 风扇调到最大 | model |
| `oscillation` | 客厅风扇摇头 | local |
| `oscillation` | 打开风扇摇头 | local |
| `oscillation` | 关闭摇头 | local |
| `oscillation` | 停止摇头 | local |
| `oscillation` | 风扇不要摇头 | local |
| `oscillation` | 客厅风扇摆风 | local |
| `oscillation` | 关掉摆头 | local |
| `oscillation` | 风扇摇头打开 | local |
| `cover` | 打开客厅窗帘 | model |
| `cover` | 关闭窗帘 | model |
| `cover` | 把窗帘拉开 | model |
| `cover` | 窗帘开到一半 | model |
| `cover` | 客厅窗帘打开50% | model |
| `cover` | 关上窗帘 | model |
| `cover` | 窗帘停一下 | model |
| `cover` | 把客厅窗帘拉到30% | model |
| `cover` | 打开窗帘 | model |
| `cover` | 客厅窗帘合上 | model |
| `cover` | 窗帘半开 | model |
| `cover` | 把窗帘关到20% | model |
| `scene` | 回家模式 | local |
| `scene` | 观影模式 | local |
| `scene` | 执行回家模式 | local |
| `scene` | 启动观影模式 | local |
| `scene` | 切换到回家模式 | local |
| `scene` | 打开回家模式 | local |
| `scene` | 睡眠模式 | local |
| `scene` | 进入观影模式 | local |
| `scene` | 回家场景 | local |
| `scene` | 执行观影场景 | local |
| `scene` | 观影 | local |
| `scene` | 把家里的灯调成观影模式 | model |
| `state_query` | 书房灯开着吗 | model |
| `state_query` | 客厅空调开着吗 | model |
| `state_query` | 书房灯现在什么状态 | model |
| `state_query` | 空调多少度 | model |
| `state_query` | 客厅温度是多少 | model |
| `state_query` | 房间湿度多少 | model |
| `state_query` | 净化器开着吗 | model |
| `state_query` | 风扇在几档 | model |
| `state_query` | 哪些灯开着 | model |
| `state_query` | 家里有没有设备开着 | model |
| `state_query` | 客厅灯亮着吗 | model |
| `state_query` | 扫地机在哪 | model |
| `state_query` | 书房台灯关了没 | model |
| `state_query` | 空调现在设置多少度 | model |
| `state_query` | 现在有几个灯开着 | model |
| `state_query` | 客厅窗帘开着吗 | model |
| `timer` | 10分钟后关闭书房灯 | local |
| `timer` | 半小时后关空调 | local |
| `timer` | 20分钟后打开客厅空调 | local |
| `timer` | 3分钟后关灯 | local |
| `timer` | 一小时后关风扇 | local |
| `timer` | 5分钟后把书房灯关掉 | local |
| `timer` | 十分钟后关书房台灯 | local |
| `timer` | 30秒后关灯 | local |
| `timer` | 定时10分钟关灯 | model |
| `timer` | 两小时后关空调 | local |
| `timer` | 15分钟后关闭客厅主灯 | local |
| `timer` | 半个小时后开灯 | local |
| `timer` | 取消定时 | none |
| `timer` | 撤销定时 | none |
| `timer` | 关灯后告诉我 | model |
| `timer` | 撤销 | none |
| `polite_form` | 请问打开书房灯 | model |
| `polite_form` | 麻烦关闭客厅空调 | local |
| `polite_form` | 谢谢打开客厅主灯 | model |
| `polite_form` | 麻烦你把书房的灯关掉 | model |
| `polite_form` | 请帮我打开客厅落地灯 | local |
| `polite_form` | 能否打开书房台灯 | model |
| `polite_form` | 可以帮我关掉风扇吗 | model |
| `polite_form` | 我想要打开客厅灯 | model |
| `polite_form` | 能不能把空调调到26度 | model |
| `polite_form` | 请问一下书房灯开着吗 | model |
| `polite_form` | 那个麻烦关一下灯 | model |
| `polite_form` | 帮我把客厅窗帘打开 | model |
| `out_of_domain` | 今天天气怎么样 | model |
| `out_of_domain` | 现在几点了 | model |
| `out_of_domain` | 帮我锁门 | model |
| `out_of_domain` | 锁定大门 | model |
| `out_of_domain` | 打开门锁 | model |
| `out_of_domain` | 播放音乐 | model |
| `out_of_domain` | 暂停播放 | model |
| `out_of_domain` | 电视声音小一点 | model |
| `out_of_domain` | 扫地机开始清扫 | model |
| `out_of_domain` | 让扫地机回充 | model |
| `out_of_domain` | 明天要带伞吗 | model |
| `out_of_domain` | 给我讲个笑话 | model |
| `out_of_domain` | 你叫什么名字 | model |
| `out_of_domain` | 空调滤芯还有多久 | model |
| `out_of_domain` | 家里安全吗 | model |
