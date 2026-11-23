# 03 用"数据而非代码"适配海量设备

- 调研日期：2026-11-23
- 范围：外部项目如何用声明式数据（定义表 / 覆盖表 / 迷你 DSL / 生成式模型）承接"型号长尾"，以及我们双端平行合成逻辑（`MiotSynthesizer.swift` + `synthesis.ts`）的数据化迁移路径。
- 实际读了源码的仓库（浅克隆，`--depth 1 --filter=blob:none`，只读不运行）：
  - `Koenkk/zigbee-herdsman-converters` @ `ed29f80`（2026-11-22，release 26.136.0）
  - `zwave-js/node-zwave-js` @ `03756e4`（2026-11-21）
  - `home-assistant/core`（sparse：`components/mqtt`、`helpers`、`components/{sensor,binary_sensor,light,switch}`）
  - `esphome/esphome` @ `39ee5d5`（2026-11-22）
  - `project-chip/connectedhomeip`（sparse：`src/app/zap-templates/zcl/data-model`、`templates`）
  - `matter-js/matter.js` @ `42aab0c`（2026-11-23）
  - `al-one/hass-xiaomi-miot` @ `8ac4df7`（2026-11-18）、`merdok/homebridge-miot` @ `d27d98f`（2026-11-18）——只补数据组织方式，不重复已有调研
  - `arendst/Tasmota`、`blakadder/templates`（模板库形态）
  - `Koenkk/zigbee2mqtt` @ `3c841fd`（2026-11-01，只看 exposes 的第二个消费者）
- 本仓库基线：`9fc349d0`（2026-11-23）

---

## 0. 结论先行

1. 六个项目最后收敛成同一个形状：**一份"设备/能力 → 行为"的声明数据 + 一个薄解释器 + 覆盖全语料的不变量测试**；差别只在数据放在 TS 对象里还是 JSON 里，而不在"要不要数据化"。【源码：zhc `src/devices/*` + `src/lib/modernExtend.ts`；zwave-js `packages/config/config/devices/**`；Matter `zcl.json`；ESPHome `components/*/__init__.py`】
2. 真正决定成败的不是"是否 JSON"，而是**把可枚举的决策收敛成受约束的封闭词汇表**：zhc 的 13 种 expose 类型 + 173 个 preset、Tuya 的具名 `valueConverter`、ESPHome 的 `SensorKind`、Matter 的 conformance 表达式。词汇表外的需求一律回落到"通用兜底"，不允许往数据里塞任意代码。【源码：zhc `src/lib/exposes.ts:953`、`src/lib/tuya.ts:1608`；esphome `components/sensor/__init__.py:428`】
3. 这个规模是真实的：zhc 有 409 个设备定义文件、去重后 **5332** 个 `model:`、**559** 个 vendor；zwave-js 有 **2409** 份设备 JSON、**18373** 个参数条目、**134** 份文件使用 `$if` 条件；Matter 有 **365** 个生成元素文件，验证器要求元素数 **≥3582**。【源码，均为本地 `grep/wc` 计数】
4. "测试数千型号"靠的是三层而不是逐型号用例：**全局不变量**（每条定义都过同一组断言）、**索引完整性**（每个文件都被 import、model 不重名）、**语料重放**（真实规格/配置重放 + 结果快照）。zhc 的 `checks.test.ts` 就是第一层的教科书样例。【源码：zhc `test/checks.test.ts:11-410`、`test/index.test.ts`、`src/indexer.ts`；zwave-js `maintenance/lintConfigFiles.ts`】
5. zwave-js 证明"JSON 里的迷你 DSL"可以长期维护，前提是**语法极小**：`$if` 只认 4 个变量（manufacturerId/productType/productId/firmwareVersion）和 `< <= > >= === && || ()`，`$import` 只做对象拼接与覆盖，**没有任意求值**。这正好是 ADR-0023"封闭内置、拒绝进程内第三方代码"的 JSON 版实现路径。【源码：zwave-js `packages/config/src/JsonTemplate.ts:22`、`docs/config-files/conditional-settings.md`】
6. Home Assistant 走的是反方向：**不维护设备库**，让设备自己声明（MQTT discovery / ESPHome YAML），平台只提供**受枚举约束的语义字段**（`device_class` / `state_class` / 单位表）和 `EntityDescription` 数据类，前端按语义渲染。对我们的启示是"卡片外观应由语义字段推导，而不是给每个型号画一张卡"。【源码：`homeassistant/components/mqtt/discovery.py:213/336`、`components/sensor/entity.py:46`、`components/sensor/const.py:651`、`helpers/entity.py:286`】
7. 我们已经有一半：`deviceProfiles.json`（281 行）与 `fallbackSpecs.json`（729 行）双端**逐字节相同**并由测试守住；`MiotFacetEngine` 已是"数据驱动引擎"；`miot_coverage_golden.json` 已重放 **208** 份真实规格 / **177** 个设备类型。缺的不是基础设施，而是把**认领阶梯、状态词表、标签表**这三块从代码搬进数据。【源码：`Tests/MijiaCoreTests/MiotFacetsTests.swift:208`、`MiotFallbackSpecTests.swift:7`、`Tests/Fixtures/miot_coverage_golden.json`】
8. 现存漂移可以举证：Windows 的 `preferredMiotServices` 有 `stb → television` 的同义映射、`primaryMiotService` 的优先级数组里有 `television`，Swift 两处都没有，且 Swift 的服务注册表里**根本没有** `television` 条目；结果 `miot_coverage_golden.json` 里唯一一条 `windowsDivergences` 正是 `123888.tv.xhzn11`（Windows `matched/television`，macOS 落到通用卡）。**同一份语料只能"记录"差异，不能"消除"差异**——这是双份代码的结构性上限。【源码：`windows/src/core/miCloud/synthesis.ts:721-733,734+`、`Sources/MijiaCore/MiCloud/MiotSynthesizer.swift:36-80,517-525`、`windows/tests/miotCoverage.test.ts:87`】
9. 最安全的切入点是"纯字符串表"：两端各有一份 **82 条** facet 标题和 **30 条**设备类型标题，键集完全一致、内容逐字重复（合计 112 条），还有 macOS 的 SF Symbol 名被抄进 Windows 词汇表（`"fish.fill"` / `"scalemass.fill"` 等）。这三处迁移零语义风险、可当天验证。【源码：`Sources/MijiaCore/MiotFacetText.swift:8,94`、`windows/src/core/miotFacetText.ts:12,56,242,248`】
10. ADR-0011 的"形状阶梯"其实只落地了一半：现在只有"注册表命中（第 2 级）→ 通用控件（第 4 级）"，**第 3 级形状检测不存在**（代码里的 `MiotCardShape` 只是卡片身份 id/name/category/signals，不是 cover/appliance/readout/actions 那套谓词）。这是覆盖率从 69/208 matched 走向更高比例的关键缺口，也是最适合用数据表达的层。【源码：`MiotSynthesizer.swift:1675-1775`、`Tests/MijiaCoreTests/MiotCoverageBaselineTests.swift:10,30`】

---

## 1. Koenkk/zigbee-herdsman-converters：组合式定义 + 封闭 exposes

### 1.1 第一层：它是什么

Zigbee2MQTT 的设备支持库，把 Zigbee 设备的 ZCL 语义翻译成 MQTT 主题与 payload。规模：`src/devices/` 409 个定义文件 + `index.ts` 汇总，`src/` 共 27 万行 TS；`model:` 去重 5332 个、vendor 559 个。【源码，本地计数】

### 1.2 第二层：数据形状

一条定义就是一个普通对象（`src/devices/tuya.ts:4803` 是个典型例子）：

```ts
{
  fingerprint: tuya.fingerprint("TS0601", ["_TZE200_8ygsuhe1", ...]),
  model: "TS0601_air_quality_sensor",
  vendor: "Tuya",
  description: "Air quality sensor",
  fromZigbee: [legacy.fromZigbee.tuya_air_quality],
  toZigbee: [],
  exposes: [e.temperature(), e.humidity(), e.co2(), e.voc().withUnit("ppb"), e.formaldehyd()],
}
```

更"数据化"的写法（同文件 `:4809`）只留 `extend` + `meta`：

```ts
extend: [tuya.modernExtend.tuyaBase({dp: true})],
meta: { tuyaDatapoints: [[2,"co2",tuya.valueConverter.raw], [18,"temperature",tuya.valueConverter.divideBy10], ...] },
```

**关键设计**：`meta.tuyaDatapoints` 是一张 `[dpId, 属性名, 具名转换器]` 的表；转换器是 `valueConverter` 这个封闭字典里的具名常量（`raw` / `divideBy10` / `divideBy100` / `lookup` / `scale` …，`src/lib/tuya.ts:1608-1650`）。型号怪癖不需要写新代码，只需要在表里挑一个已有转换器。全仓 `tuyaDatapoints` 出现 **344** 次。【源码】

### 1.3 第三层：三个机制

**(a) modernExtend = 能力组合**

`ModernExtend` 是一个"定义片段"接口：`{fromZigbee?, toZigbee?, exposes?, configure?, meta?, ota?, options?, onEvent?, endpoint?, isModernExtend}`（`src/lib/types.ts:253-264`）。`prepareDefinition()` 调 `processExtensions()` 把这些片段**按字段合并**（数组拼接、对象合并），再补上全局 `toZigbee` 命令集（`src/index.ts:256-300,420-470`）。所以"电池""电量计量""窗帘"这类能力各写一次工厂函数（`m.battery()`、`m.electricityMeter()`），数千型号调用组合，而不是复制实现。

**(b) exposes = 封闭词汇表，双消费者**

`Expose` 是 13 种类型的联合：`Numeric | Binary | Enum | Composite | List | Light | Switch | Lock | Cover | Climate | Fan | Text`（`src/lib/types.ts:40-52`），每种都带 `access`、`category`（`config`/`diagnostic`）、`unit`、`valueMin/Max/Step`、`homeassistant` 元数据；`presets` 里预置了 **173** 个具名工厂（`e.temperature()`、`e.co2()`、`e.battery()`…），另有 **25** 个 `options` 工厂（`src/lib/exposes.ts:953+`）。

同一份 exposes 被两个消费者读取：

- 前端：`lib/extension/bridge.ts:948` 把 `device.exposes()` 原样塞进 `/devices` 响应，前端按 `type` 通用渲染；
- Home Assistant：`lib/extension/homeassistant.ts:622` 的 `exposeToConfig()` 把同样的 exposes 翻译成 discovery 配置（light 会检查是否有 `color_xy`/`color_hs`/`brightness`/`color_temp` 等 feature 再决定 payload）。

这一条对我们最直接：**"给用户看的卡片"和"给外部平台的能力声明"应该是同一份数据的两个投影**，而不是两份手写实现。

**(c) 测试数千型号 = 全语料不变量**

`test/checks.test.ts` 不逐型号断言，而是 `beforeAll` 把全部定义 `prepareDefinition` 后遍历，跑 11 类不变量，例如：

- `Exposes access matches toZigbee`（`:44`）——每个可写 expose 必须能在 `toZigbee` 里找到对应转换器；
- `Exposes properties are unique`、`Model should be unique`、`Number exposes with set access should have a range`、`Vendor names should be consistent in casing`、`respect snake case naming conventions`；
- `test/index.test.ts` 里另有 `check if all definitions are imported in devices/index.ts`（孤儿文件检测）与大量 fingerprint 命中测试。

索引本身也是生成物：`src/indexer.ts` 扫描 `src/devices/*`，产出 `models-index.json`（`Record<zigbeeModel, [file, index][]>`），并顺手检测重复 fingerprint / 重复 model。

### 1.4 为什么这样做，代价是什么

- **为什么**：型号长尾的本质是"同一批能力的不同组合 + 少量怪癖"。把能力拆成可组合片段（modernExtend）、把展示面收敛成封闭词表（exposes），新增型号的边际成本就从"写解析器"降到"填表"。
- **代价**：定义仍然是 **TS 代码**，不是纯数据——`exposes: (device) => [...]` 可以是函数，`configure` 可以是任意代码。可维护性靠 **PR 期的人工评审 + 全语料不变量**兜住，而不是靠 schema。超大文件（`tuya.ts` 32528 行）是这条路线的副作用。`AI_POLICY.md` 明确要求贡献者本人能解释改动——说明维护者把"定义质量"当成人工责任而非机器保证。【源码/文档】

---

## 2. zwave-js：JSON 设备库 + 迷你 DSL

### 2.1 数据形状

`packages/config/config/devices/<manufacturerId>/<device>.json`，**2409** 份，按厂商 4 位十六进制 ID 分目录。一份文件描述"一组 productType/productId + 固件范围 + 关联组 + 参数表 + compat 标志 + 元数据"（`docs/config-files/file-format.md`）。参数条目共 **18373** 个。【源码】

核心是"参数即数据"：

```json
{ "#": "3", "label": "LED Light", "valueSize": 1, "defaultValue": 1,
  "allowManualEntry": false,
  "options": [{"label": "LED on when load is off", "value": 0}, ...] }
```

位域参数用 `"#": "40[0x01]"` 表达（`docs/config-files/partial-parameters.md`）：把同一个字节拆成多个"部分参数"，`min/max/default` 相对最低位，位移由运行时算。**这是"用数据表达协议怪癖"最干净的一例**。

### 2.2 `$import`：复用而不是复制

980 份文件用了 `$import`（本地计数）。语法两种形态：

- `"$import": "~/templates/master_template.json#orientation"` —— 从模板里取一个具名片段；
- `"$import": "template.json"` —— 整文件继承，本地键覆盖（且"`$import` 之后的键优先于模板"）。

实现只有 300 行左右（`packages/config/src/JsonTemplate.ts:22` `readJsonWithTemplate`），支持深层 import、数组内 import、循环检测，并对模板文件做缓存。**没有求值，只有拼接**。

对我们的直接映射：`fallbackSpecs.json` 里 12 条规则各自内嵌一整份 spec，重复的 `on`/`brightness` 属性块可以抽成 `#fragment` 复用——这正是 `$import` 解决过的问题。

### 2.3 `$if`：只够用就好的条件 DSL

`docs/config-files/conditional-settings.md` 定义的条件语言只有：变量 `manufacturerId/productType/productId/firmwareVersion`，运算符 `< <= > >= ===`、`&& || ()`，出现在参数、选项、endpoint、metadata、compat 等位置。数组形态表示"第一个命中的变体生效，最后一项是兜底"。

134 份文件使用它（本地计数）。这条设计经验值得抄：**条件语言必须小到可以一次读完、可以静态检查、可以确定性地解释**。一旦允许 JS eval，ADR-0023 的封闭性就没了。

### 2.4 compat：声明式怪癖清单

`maintenance/schemas/device-config.json:646` 的 `compatFlags` 是一张受 schema 约束的对象：`alarmMapping`、`remapNotifications`、`mapBasicSet`、`forceNotificationIdleReset` 等，每项都有类型和取值范围。**非兼容设备的每一种"哄法"都是一个具名标志，不是一段代码。**

这正是 ADR-0011 草案里 `quirks` 字段该长成的样子：**若干具名、带类型、可单独校验的开关**，而不是一个可以塞任意 JSON 的"杂项袋"。（当前 `deviceProfiles.json` 的 `overrides[]` 只有 `highlight`/`readouts`/`feeding` 这类展示字段，`quirks` 尚未实现。）

### 2.5 质量门禁

- `maintenance/schemas/device-config.json`：JSON Schema，`additionalProperties: false`，参数必须满足 `valueSize` 与 `min/max` 的一致性；
- `packages/config/maintenance/lintConfigFiles.ts`（1000+ 行）：跨文件检查，包括位域合法性（`getLegalRangeForBitMask`）、标签拼写疑似错误（引入 `js-levenshtein` 做近似重复检测）、条件表达式解析（`parseLogic`）；
- `packages/config/src/ConfigManager.test.ts` + `JsonTemplate.test.ts`：模板语义与边界。

**2409 份数据文件能长期不烂，靠的是"schema + lint + 语义测试"三件套，而不是人工记忆。**

---

## 3. Home Assistant 一侧：让设备自己描述

### 3.1 MQTT discovery：协议即 schema

HA 不为设备建库。设备把"我有哪些实体、每个实体什么语义"发到 `homeassistant/<component>/<node>/<object>/config`，HA 用每个平台的 discovery schema（`probatio` 校验）验证后建实体。

两个细节值得学：

1. **缩写表**：`abbreviations.py:3` 定义了 **291** 条 `短名 → 全名` 映射（`dev` → `device`、`dev_cla` → `device_class`、`cmd_t` → `command_topic`…），`discovery.py:213` 在解析前统一展开。这是为了 MQTT payload 体积——**用一张纯数据字典换取传输效率，同时保持内部字段名完整**。
2. **device-based discovery**（`discovery.py:336` `_async_parse_device_discovery`）：一个 payload 里带 `cmps`（components）字典，HA 把它**展开成每个子实体的 config**。也就是"整机描述 → 多实体"的官方模式——和我们的"一张设备卡 + 抽屉控件"是同构的。

### 3.2 EntityDescription：语义数据类 + 枚举约束

```python
class EntityDescription(metaclass=FrozenOrThawed, frozen_or_thawed=True):
    key: str
    device_class: str | None = None
    entity_category: EntityCategory | None = None
    unit_of_measurement: str | None = None
    ...
```

（`homeassistant/helpers/entity.py:286-302`；传感器版本在 `components/sensor/entity.py:46-56`，多出 `state_class` / `native_unit_of_measurement` / `suggested_display_precision`。）

真正让它"数据化"的是三张约束表：

- `DEVICE_CLASS_UNITS: dict[SensorDeviceClass, set[unit]]`（`components/sensor/const.py:651`）：**每种语义允许哪些单位**，写错单位在校验期就报错；
- `UNIT_CONVERTERS`（同文件 `:607`）：单位换算器按 `device_class` 查表，而不是散落在各集成里；
- `STATE_CLASSES_SCHEMA` / `DEVICE_CLASSES_SCHEMA`：枚举校验。

语义字段一旦受约束，前端（Lovelace / 卡片）就能**按语义渲染**：`device_class=battery` 自动得到电池图标和百分比格式，不需要集成告诉前端画什么。

### 3.3 ESPHome：配置 schema → 代码生成

ESPHome 的"设备描述"是 YAML；每个组件用 `cv.Schema` 声明自己的配置（sensor 的 `_SENSOR_SCHEMA`，`components/sensor/__init__.py:376-425`），平台多态用 `cv.typed_schema(schemas, key="platform")` 分派（`config_validation.py:2334`），最后 `codegen` 生成 C++。876 个组件目录都遵循这套。

最新版本引入的 `SensorKind` 很值得抄（`components/sensor/__init__.py:428-470`）：

```python
TEMPERATURE = SensorKind(UNIT_CELSIUS, DEVICE_CLASS_TEMPERATURE, accuracy_decimals=1)
HUMIDITY    = SensorKind(UNIT_PERCENT, DEVICE_CLASS_HUMIDITY, accuracy_decimals=1)
ENERGY_KWH  = SensorKind(UNIT_KILOWATT_HOURS, DEVICE_CLASS_ENERGY, STATE_CLASS_TOTAL_INCREASING, accuracy_decimals=3)
```

**一个具名 kind 把"单位 + 语义 + 精度 + 图标 + state_class"打包**，调用方只写 `sensor_schema(kind=sensor.TEMPERATURE)`。这正是 ADR-0011 说的"按控制形状建模"的最小可用形态：形状 = 一组语义默认值，而不是一段渲染代码。

### 3.4 Tasmota：反面教材（压缩过头的"数据"）

Tasmota 模板是位置化 JSON：

```
{"NAME":"Asakuki","GPIO":[0,2272,0,2304,0,0,0,0,0,0,0,0,0,0],"FLAG":0,"BASE":54,
 "CMND":"TuyaMCU 11,1 | TuyaMCU 12,11 | TuyaMCU 21,111 | ..."}
```

（`TEMPLATES.md`，社区库 `blakadder/templates` 有 **2871** 个 `_templates/*.md` 页面，frontmatter 里塞同一串 JSON，再由 Jekyll 生成 `templates.json` 索引。）

`GPIO` 是**按下标对齐芯片引脚**的数组——省字节、不可读、不可 diff、错一位就烧错引脚。`CMND` 则是命令串拼接（`TuyaMCU <fnId>,<dpId>`），相当于把 DSL 退化成字符串管道。

教训很明确：**数据化 ≠ 压缩。**可读性、可 diff、可校验、可局部 review 是数据文件能长期维护的前提；`"GPIO": [0,2272,...]` 这类位置编码在我们这里应当明令禁止。

---

## 4. Matter：从规范到生成物的单向流水线

三层链路，全部机械可复现：

1. **数据模型（唯一真源）**：`connectedhomeip` 的 `src/app/zap-templates/zcl/data-model/chip/*-cluster.xml`（**144** 个集群 XML）+ `matter-devices.xml`（设备类型，头部注释列出 100+ 个 `.adoc` 源文件）。
2. **清单**：`zcl.json` 显式列出 **157** 个 `xmlFile` 及其顺序（并注明"`access-control-definitions.xml` 必须第一"）；`app-templates.json` 显式列出每个 `.zapt` 模板 → 输出文件名。
3. **生成物**：`devices-Ids.h` / `devices-Types.h` / `endpoint_config.h` / 集群编解码 …；Matter.js 侧同样把 XML 转成 `packages/model/src/standard/elements/*.element.ts`——**365 个文件，每个头部都写 `THIS FILE IS GENERATED, DO NOT EDIT`**。

设备类型本身**就是纯声明**：`AirPurifier` 只写"必须有哪些 cluster / device type、哪些可选"（`matter-js/packages/model/src/standard/elements/air-purifier.element.ts`）：

```ts
DeviceType({ name: "AirPurifier", id: 0x2d, classification: "simple" },
  Requirement({ name: "Identify", id: 0x3, conformance: "M", element: "serverCluster" }),
  Requirement({ name: "FanControl", id: 0x202, conformance: "M", element: "serverCluster" }),
  Requirement({ name: "AirQualitySensor", id: 0x2c, conformance: "O", element: "deviceType" }), ...)
```

`OnOff` 集群则用 `conformance: "LT"` / `"!OFFONLY"` 表达特性依赖（`on-off.element.ts`）。

**质量手段**：`packages/model/test/standard/MatterDefinitionTest.ts` 做模型校验，并有**规模棘轮**——`expect(validate().elementCount).least(3582)`（`:45`）。生成的模型只能变大不能变小，防止生成器悄悄丢元素。这和我们 `miot_coverage_golden.json` 里 `summary.categories` 的作用完全一致。

**对我们的意义**：如果我们把合成规则写成单一 JSON，理想终态就是这条流水线——"规则 JSON → Swift struct / TS 类型 / 文档"由生成器产出，人只改 JSON 和 schema。但那是第 5 期的事，前面必须先有稳定的词汇表。

---

## 5. al-one 与 homebridge-miot：覆盖表怎么组织（增量）

已有调研讲过两者的解析阶梯，这里只补**数据组织**：

- `al-one/hass-xiaomi-miot`：
  - `custom_components/xiaomi_miot/core/device_customizes.py`：**3957 行**的 `DEVICE_CUSTOMIZES: dict[model_pattern, dict]`，值是"配置覆盖"（`sensor_properties`、`exclude_miot_properties`、`chunk_coordinators`、`append_converters`…）。**覆盖项是键值对，不是代码**，但有例外：`append_converters` 里能塞 `{'class': MiotClimateConv, ...}` 这种类引用——即"数据里带代码指针"。
  - `core/miot_specs_extend.json`：**2057 行**纯 JSON，用来给官方 spec 打补丁（补缺失属性/服务）。
  - 匹配策略在 `core/utils.py:255-262`：从 `a.b.c` 推出 `a.b.*`、`*.b.*`、`*` 三级通配候选——**同一份覆盖表按"具体 → 泛化"自动降级**。这个 4 级阶梯比我们的"型号精确 + `*` 通配"更省条目。
- `merdok/homebridge-miot`：`lib/factories/{AccessoryFactory,DeviceFactory,MatterAccessoryFactory}.js`（147 行等）+ `lib/modules/custom/`。**覆盖表退化成了"工厂 + 自定义模块目录"**，配置面只剩 `config.schema.json` 里的少量开关。对比 al-one，这条路线的"数据性"更低、可维护性更依赖代码结构——但它支持到 Matter，说明"同一份 spec 生成多种输出"是可行的。

两者共同点：**覆盖键用型号通配符，覆盖值用固定字段集，绝不引入表达式**。这是我们 `deviceProfiles.json` 的 `overrides[].models` 已经在做的事，只是字段还不够。

---

## 6. 对照我们：差距表

先给现状基线（全部本地可核）：

| 双份实现 | Swift | TypeScript |
| --- | --- | --- |
| 米家合成器 | `Sources/MijiaCore/MiCloud/MiotSynthesizer.swift` 1920 行 | `windows/src/core/miCloud/synthesis.ts` 2081 行 |
| 控件引擎 | `Sources/MijiaCore/MiCloud/MiotFacets.swift` 771 行 | `windows/src/core/miCloud/facets.ts` 573 行 |
| 标签/文案 | `Sources/MijiaCore/MiotFacetText.swift` 230 行（82 条中文名） | `windows/src/core/miotFacetText.ts` 302 行（41+42 条标题） |
| HA 合成器 | `Sources/MijiaCore/DeviceSynthesizer.swift` 2135 行 | `windows/src/core/haDomains.ts` 1461 行 + `models.ts` |
| 共享数据 | `Resources/deviceProfiles.json` 281 行、`Resources/fallbackSpecs.json` 729 行 | 同名文件逐字节相同 |

| 我们文件 | 现状 | 对标做法 | 建议 | 成本 |
| --- | --- | --- | --- | --- |
| `MiotSynthesizer.swift:36-80` `registry` + `:509-565` `primary(for:)` | 服务→builder 的有序表在 Swift 里；Windows 另有一份 `priority` 数组（`synthesis.ts:734+`）且把 `television/stb` 当作特例，Swift 两者都没有 | zhc：能力用 `modernExtend` 工厂组合，定义只写"用哪些能力"；zwave-js：参数是可枚举的数据行 | 把"服务 → 卡片种类 + 认领谓词"搬进 `deviceProfiles.json`，两端只保留一个按序求值的解释器；`television/stb` 这类差异由数据统一 | M |
| `MiotSynthesizer.swift:517` `preferredServices`（3 个硬编码 case + 默认 `[deviceType]`） | 同义映射写死在代码；Windows 版本多一条 `stb` | al-one：`a.b.c → a.b.* → *.b.* → *` 四级通配降级 | 改为数据里的 `aliases: {type: [service,…]}`，并支持同样的通配降级 | S |
| `MiotSynthesizer.swift:574-583` `claims`（`water-heater` / `electronic-valve` 特判） | 谓词是命令式 if | zwave-js `compatFlags`：具名标志 + schema 约束 | 定义封闭谓词词汇：`requiresService` / `requiresProperty` / `requiresAnyOf`，数据里组合 | M |
| `MiotSynthesizer.swift:409-446` `genericTypeTitle`（内联 30 条中文） vs `miotFacetText.ts:242` `DEVICE_TYPE_TITLES`（同样 30 条） | **逐字重复**，且绕过 L10n/i18n | zhc：文案走 preset 的 `withLabel`，一处定义 | 搬进 `Shared/deviceLabels.json`，两端查表；中文/英文都进资源而非代码 | S |
| `MiotFacetText.swift:8-90` 82 条 `chineseNames` vs `miotFacetText.ts:12/56` 41+42 条标题 | **键集完全相同**（82 条），内容重复 | ESPHome `SensorKind`：具名 kind 打包语义默认值 | 同上，合并成一份 `facetTitles`；同时把 `FAMILY_*` 的"泛化匹配"规则数据化 | S |
| `MiotSynthesizer.swift:447-474` `genericSymbolName` 返回 SF Symbol 名；Windows `miotFacetText.ts:248` 抄同一批名字 | 平台专有词汇混进共用语义 | Matter：`device_class` 这类中性语义字段，平台各自映射 | 数据里只存**语义图标 id**（`tv` / `fish-tank`），Swift 映射 SF Symbols、TS 映射自己的图标集 | S |
| `MiotSynthesizer.swift:1494-1568` 状态词阶梯（`hvacMode` 5 条 case、`vacuumStatus` 6 条分支、`applianceStatusText` 3 条 case、`genericApplianceStatusText` 10 条 substring 分支） | 有序判定阶梯写在代码，TS 侧逐条重写成另一套 | zwave-js `$if` + 选项表；zhc `valueConverter` 具名转换 | 改为有序规则数组 `[{anyOf:[…], textKey:"Cleaning"}]`，解释器两端共用；保留"先具体后泛化"的顺序语义并用测试锁定 | M |
| `MiotSynthesizer.swift:1675-1775` `cardShapes` | ADR-0011 第 3 级"形状检测"缺失：只能注册表命中或落到通用控件 | ADR-0011 表格本身（cover/appliance/readout/actions/composite/generic 的谓词）；ESPHome `SensorKind` | 在数据里写形状谓词（可枚举的条件组合），解释器按序求值；这是覆盖率提升的主路径 | L |
| `Resources/fallbackSpecs.json` | 12 条规则内嵌完整 spec，重复的 `on/brightness` 块逐条复制 | zwave-js `$import` + `~/templates/…` | 加 `fragments` 区 + `#fragment` 引用；JSON 体积可降一半，且新增型号只写差异 | S |
| `Tests/Fixtures/miot_coverage_golden.json` `windowsDivergences`（1 条） | 用白名单"记录"双端差异（`windows/tests/miotCoverage.test.ts:87`） | Matter `elementCount ≥ 3582` 棘轮；zhc 全语料不变量 | 保留棘轮，但把 `windowsDivergences` 变成"只减不增"的债务表，并加"同一 fixture 两端必须同分类"的强断言（迁移完成后清空） | S |
| `scripts/check_capability_manifest.py:47-168` | 已有"严格 JSON + 未知/重复 ID + 依赖环 + 跨语言文本比对"的门禁范式 | zwave-js schema + lint；Matter `zcl.json` 清单 | 复制这套范式做 `check_device_rules.py`：schema、引用完整性、歧义（两条规则命中同一 fixture）、棘轮 | M |
| `Resources/deviceProfiles.json` 只有 `noise/alerts/facets/manualControlPolicy/overrides/fallbackClaims/appliances` | 数据面覆盖"展示与风险"，不覆盖"认领与状态语义" | 见上 | 扩成 `synthesis` 段（aliases / claims / builders / shapes / statusWords），保持单文件、单版本号 | L |

---

## 7. 迁移方案：一份共享声明 + 两个薄解释器

### 7.1 目标形态

```
Shared/deviceProfiles.json          # 唯一可写真源（人改这里）
  ├─ schemaVersion, noise, alerts, facets, manualControlPolicy   （现有，不动）
  ├─ aliases      : 设备类型 → 首选服务列表 + 通配降级
  ├─ claims       : 服务 → 认领谓词（封闭词汇）
  ├─ builders     : 服务 → 卡片 builder 名（封闭枚举，映射到两端已有的函数）
  ├─ shapes       : 形状谓词表（cover/appliance/readout/actions…，按序）
  ├─ statusWords  : 有序状态词阶梯（描述 → 语义 key）
  ├─ labels       : facet/设备类型标题（语义 key，不含语言文本）
  └─ overrides    : 型号/通配覆盖（扩展 quirks 字段）
```

原则（每条都能在外部项目里找到依据）：

1. **数据只放"选择"，不放"计算"**。允许的字段类型只有：字符串枚举、数字、有序数组、`{anyOf:[…]}`、`{firstMatch:[…]}`、`#fragment` 引用。禁止表达式、禁止函数名之外的代码指针（zhc/al-one 的教训：一旦允许代码指针，数据就退化成代码）。【依据：zwave-js `$if` 只 4 个变量；ADR-0023 第 1 条】
2. **builder 是封闭枚举**，名字映射到两端各自已有的实现（`buildLight` ↔ `buildLight`）。数据只决定"哪个型号用哪个 builder"，决定不了 builder 内部怎么写。这样第一/二期不必重写 1900 行 builder。【依据：zhc modernExtend + 固定 builder 集；ADR-0023"封闭内置"】
3. **顺序即语义**，且顺序必须显式可测：任何两条规则命中同一 fixture 视为"歧义"，由 lint 报错（或要求前一条更具体）。【依据：zwave-js `$if` 数组"第一个命中生效"；al-one 通配降级】
4. **标签存语义 key，不存语言文本、不存平台图标名**。中文/英文进各端资源；图标走语义 id。【依据：HA `device_class` 是中性语义；ESPHome kind 也是中性】
5. **每次改动都要能在 `miot_coverage_golden.json` 上说出覆盖率变化**（matched / generic / noUsable 的增减）。【依据：Matter `elementCount ≥ N`；ADR-0011 后果段】

### 7.2 分期

**P1（S，1–2 天/期）——搬"叶子表"，零语义风险**

- `labels`：112 条标题（82 facet + 30 设备类型）合并进 `Shared/deviceLabels.json`；
- `statusWords`：`hvacMode` / `vacuumStatus` / `applianceStatusText` / `genericApplianceStatusText` 四张阶梯搬成有序数组，两端各写 ~40 行解释器（返回语义 key，文案仍由各端 L10n 出）；
- 门禁：`labels`/`statusWords` 的 key 集必须被两端代码引用（防孤儿），引用必须存在（防拼错）；沿用 `check_capability_manifest.py` 的做法，用正则从源码提取 ID 比对。
- 验证：`miot_golden.json` 的 `expectedKinds` 与快照像素基线必须零变化。

**P2（M，3–5 天）——搬"认领阶梯"**

- `aliases` + `claims` + `builders`：把 `preferredServices`（Swift）与 `preferredMiotServices`（TS）、`registry` 与 `priority` 合并成一份有序表；
- 解释器：`primary(for:)` / `primaryMiotService` 变成"读表 + 谓词求值"，两端的函数签名不变（对上层零影响）；
- 迁移验收：`windowsDivergences` 清空（`stb`/`television` 由数据统一），`miot_coverage_golden.json` 的 `matched` 数**上升**（当前 69/208），`misclaimed` 保持 0；
- 风险点：删掉注册表顺序会改变一部分设备的卡片种类 → 必须先用"当前行为"重录一份 golden 作为对照，再逐条解释差异。

**P3（L，1–2 周）——形状谓词（补 ADR-0011 第 3 级）**

- `shapes`：`{id:"cover", anyOf:[{service:"motor-control", writable:true}, …], builder:"buildCover"}`；
- 顺序：型号覆盖 → 类型+兼容表 → **形状谓词** → 通用控件 → 兜底卡；
- 验收：`genericControllable`（当前 94）里应有一批迁到 `matched`；`noUsableProperties`（31）不动（它们确实没有可控项）。
- 这是收益最大也最危险的一期：形状误判会把洗衣机的"模式"画成窗帘。必须给每个形状配"反例 fixture"（已知不该命中的规格）。

**P4（M）——`quirks` DSL 与 `$fragment` 复用**

- 覆盖表扩展：现有 `models`/`deviceTypes`/`highlight`/`readouts`/`feeding` 之外，按 ADR-0011 草案补 `exclude`、`shape`、`primaryService`、`quirks`（`positionReversed`、`labels` 等具名开关），以及 `scale`（如"注释里写 0.01kWh"这类）、`statusAliases`、`argumentDefaults`；
- `fallbackSpecs.json` 加 `fragments` + `#fragment` 引用（照 zwave-js `$import` 语义，只做对象合并与覆盖）；
- 门禁：JSON Schema（`additionalProperties: false`）+ 语义 lint（例如 `scale` 必须是 10 的整数次幂）。

**P5（M–L，可选）——生成器与文档**

- 从 JSON Schema 生成 Swift `Codable` 结构与 TS 类型（现在是手写两遍，且字段一改就双端编译错）；
- 从数据生成 `docs/platform-matrix` 的 MIoT 行（ADR-0011 把这件事留给 #185）；
- 这一步才真正逼近 Matter 的流水线：**单一真源 → 生成物 → 棘轮**。在此之前不建议做，因为没有稳定词汇表时生成器只会放大 churn。

### 7.3 风险与对策

| 风险 | 说明 | 对策 | 相关 ADR |
| --- | --- | --- | --- |
| 语义漂移而非语法漂移 | 数据统一后，两端解释器仍可能对同一条规则理解不同（例如"先具体后泛化"的排序） | 每个共享数据文件配一份"解释器一致性语料"：同一 fixture，两端必须输出**逐字段相同**的分类与控件；差异只能进"只减不增"的债务表 | ADR-0006 |
| 去重结果被连带改变 | `DeviceDeduplicator.capabilityScore`（`DeviceDeduplicator.swift:449`，Windows `dualSourceProvider.ts:539`）按合成后的控件数量打分；合成一变，双源胜出方可能翻转，用户看到的卡片来源会换 | 新增"双源配对胜出"黄金语料（现有 `capability_selection_golden.json` 只覆盖能力开关，不覆盖胜出判定），任何 `capabilityScore` 变化必须显式重录 | ADR-0008 |
| 数据变成第二套代码 | `quirks` 字段越加越多、嵌套越深，最后没人敢改 | 词汇表准入规则：新增字段必须(a)在 ≥2 个真实型号上出现，(b)能被 lint 校验，(c)不引入求值；否则先写代码 | ADR-0011、ADR-0023 |
| 违反"无进程内第三方代码" | 如果为了灵活引入表达式求值器/插件加载 | 明确写进 ADR：只允许固定变量集的比较组合（zwave-js 风格），解释器随 App 发布 | ADR-0023 第 1 条、ADR-0020 |
| 启动与内存成本 | 现在 `deviceProfiles.json` 只有 ~4.8 KB；扩到含 shapes/statusWords 后可能到 30–50 KB，两端都在启动期解码 | 保持"首次使用时懒加载 + 静态缓存"（Swift 已是 `DeviceProfiles.current` 懒加载）；在 `HomeStore+Metrics` 里加一条解码耗时指标，超过 5 ms 就改为预编译成二进制 | ADR-0003（Linux 可编译）、性能预算 |
| 覆盖表变成"谁都能改" | 数据文件门槛低，容易收进未经真机验证的怪癖 | 沿用 ADR-0011 的"低风险写入名单必须真机确认"规则：`lowRiskWrites` 类字段的改动必须在 PR 描述里附真机证据 | ADR-0011 后果段 |
| 分阶段落地造成新的 README 失真 | 一端先落数据化，另一端还在代码里 | 按 ADR-0006 要求在 README 与 ADR 里标注阶段；`windowsDivergences` 继续作为唯一例外登记处 | ADR-0006 |

---

## 8. 推进清单

| # | 标题 | 价值 | 成本 | 优先级 | 高风险面 | 依据 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `Shared/deviceLabels.json`：合并 112 条 facet/设备类型标题 | 消除逐字重复；为后续所有文案数据化立范式 | S | **P0** | 否（纯展示） | `MiotFacetText.swift:8`、`miotFacetText.ts:12,56,242` |
| 2 | 状态词阶梯数据化（4 张表 → `statusWords`） | 统一"待机/故障/清洗中"等语义，端上只留 L10n | S | **P0** | 否 | `MiotSynthesizer.swift:1494-1568`；zhc `valueConverter` |
| 3 | 图标语义化：数据只存语义 id | 去掉 SF Symbol 名跨平台泄漏 | S | **P0** | 否 | `MiotSynthesizer.swift:447`、`miotFacetText.ts:248` |
| 4 | `check_device_rules.py` 门禁（schema + 引用完整性 + 歧义 + 棘轮） | 让数据文件可安全演进；复用既有 `check_capability_manifest.py` 范式 | M | **P0** | 否 | `scripts/check_capability_manifest.py:47`；zwave-js lint |
| 5 | 认领阶梯（aliases/claims/builders）合并成数据 | 消除 `stb/television` 类漂移；新增长尾型号只改数据 | M | **P1** | 是（设备控制入口） | `MiotSynthesizer.swift:509-583`、`synthesis.ts:721-760` |
| 6 | `windowsDivergences` 从"白名单"改为"只减不增债务表"并加强一致性断言 | 让"记录差异"变成"消灭差异"的机制 | S | **P1** | 否（测试） | `windows/tests/miotCoverage.test.ts:87`；Matter 棘轮 |
| 7 | 形状谓词（补 ADR-0011 第 3 级） | 覆盖率主路径：94 个 genericControllable 中的一部分可升级为专用卡 | L | **P1** | 是（误判风险） | ADR-0011 §1；`MiotCoverageBaselineTests.swift:10` |
| 8 | `fallbackSpecs.json` 加 `fragments` + `#fragment` | 体积减半、新增型号只写差异 | S | **P2** | 否 | zwave-js `JsonTemplate.ts` |
| 9 | `quirks` 扩展（scale/statusAliases/argumentDefaults） | 把"注释里的小数点"这类怪癖从代码搬进数据 | M | **P2** | 是（单位错误会算出 100 倍电量） | `powerScale`/`energyScale` `MiotSynthesizer.swift:1447,1468` |
| 10 | 双源胜出黄金语料 | 给去重加一道闸，防止合成变更悄悄翻转卡片来源 | M | **P2** | 是（ADR-0008 语义） | `DeviceDeduplicator.swift:449`、`dualSourceProvider.ts:539` |
| 11 | 由 schema 生成 Swift/TS 类型 | 字段一改双端同时编译错，而不是运行期静默 | M | **P3** | 否 | Matter `app-templates.json` |
| 12 | 从数据生成 `docs/capabilities.json` 的 MIoT 行 | 终结手工维护能力表 | M | **P3** | 否 | ADR-0011 §6（#185 剩余项） |

---

## 9. 设想（天马行空，不受现有 ADR 约束）

1. **"规格指纹 → 卡片"的可搜索线上库**：把我们重放过的 208 份规格（法律允许范围内）做成"服务/属性组合 → 形状判定"的可检索表，社区提交"我的型号应该长这样"时只提交 JSON 覆盖行，由 CI 在同一份语料上回放。参考 blakadder 的 2871 页模板库形态，但用 JSON + schema 而不是 frontmatter。**冲突：无**（不涉及第三方代码），但与 ADR-0023"封闭内置"的边界需要在 ADR 里写清"数据可来自外部，代码不可"。
2. **形状谓词的"反例驱动开发"**：每个形状维护一组 `mustMatch` / `mustNotMatch` fixture，新增谓词必须同时提交一个反例（例如"不能把油烟机判成风扇"）。这是把 ADR-0011 的"误判"教训固化成测试资产。**冲突：无。**
3. **把合成规则编译成 SQLite/二进制缓存**：启动期直接 mmap 一张预编译的"服务名 → builder + 谓词"索引，避免每次解析 JSON。参考 Matter 的"生成物 + 清单"模式。**冲突：无**，但会增加打包复杂度。
4. **规则 DSL 的"类型检查器"**：给 `Shared/deviceProfiles.json` 写一个独立的小型类型检查器（类似 `zcl.xsd`），能在 PR 里指出"`highlight` 引用了不存在的属性名，且在 208 份语料里都没出现过"——比 JSON Schema 多一层跨文件语义。**冲突：无。**
5. **一条规则两种投影**：同一份 `shapes` 数据同时产出(a)菜单栏卡片、(b)MCP 只读快照的能力描述、(c)Raycast 扩展的命令树。现在这三处各自裁剪（`RaycastSnapshot.swift`、MCP 服务、`AppURLCommand.swift`），容易出现"面板里有、MCP 里没有"。**冲突：无**，但是 ADR-0013 的契约需要扩展。
6. **反向生成**：从我们已有的 builder 代码反向抽取"这个 builder 到底读了哪些属性"，自动生成规则的初稿，再由人审。等于给 1920 行代码做一次"数据化编译器"。**冲突：无。**

---

## 10. 来源清单

**源码（本地浅克隆，路径相对各仓库根）**

- `Koenkk/zigbee-herdsman-converters` @ `ed29f80`：
  - `src/lib/types.ts:40-52`（Expose 联合）、`:253-264`（ModernExtend）、`:116`（tuyaDatapoints 元数据）
  - `src/lib/exposes.ts:27-90`（Base 类）、`:953+`（173 个 presets + 25 个 options 工厂）
  - `src/lib/modernExtend.ts:1-120`（扩展工厂 + IAS 语义表）
  - `src/index.ts:256-300`（processExtensions 合并）、`:420-470`（prepareDefinition）
  - `src/indexer.ts:1-60`（模型索引生成）
  - `src/devices/tuya.ts:4803`（TS0601_air_quality_sensor）、`:4809`（tuyaDatapoints 写法）
  - `src/lib/tuya.ts:1608-1650`（valueConverter 封闭字典）
  - `test/checks.test.ts:11-410`（全语料不变量）、`test/index.test.ts`（索引/命中断言）
- `zwave-js/node-zwave-js` @ `03756e4`：
  - `packages/config/src/JsonTemplate.ts:22-60`（readJsonWithTemplate）
  - `packages/config/config/devices/**`（2409 份 JSON、18373 个参数、980 份 `$import`、134 份 `$if`）
  - `maintenance/schemas/device-config.json:90-100`（compat 形态）、`:646+`（compatFlags）
  - `packages/config/maintenance/lintConfigFiles.ts`（跨文件 lint）
  - `docs/config-files/file-format.md`、`conditional-settings.md`、`partial-parameters.md`
- `home-assistant/core`（sparse）：
  - `homeassistant/components/mqtt/abbreviations.py:3+`（291 条缩写）
  - `homeassistant/components/mqtt/discovery.py:213`（缩写展开）、`:336-370`（device-based discovery）、`:365`（DEVICE_DISCOVERY_SCHEMA 校验）
  - `homeassistant/helpers/entity.py:286-302`（EntityDescription）
  - `homeassistant/components/sensor/entity.py:46-56`（SensorEntityDescription）
  - `homeassistant/components/sensor/const.py:607`（UNIT_CONVERTERS）、`:651+`（DEVICE_CLASS_UNITS）
- `esphome/esphome` @ `39ee5d5`：
  - `esphome/components/sensor/__init__.py:376-425`（_SENSOR_SCHEMA）、`:428-470`（SensorKind 与 preset）
  - `esphome/config_validation.py:2334-2360`（typed_schema）
  - `esphome/core/entity_helpers.py:274`（setup_device_class）
- `project-chip/connectedhomeip`（sparse）：
  - `src/app/zap-templates/zcl/zcl.json`（XML 清单与顺序）
  - `src/app/zap-templates/app-templates.json`（模板 → 输出映射）
  - `src/app/zap-templates/zcl/data-model/chip/matter-devices.xml`（设备类型，头部列出 100+ `.adoc` 源）
  - `src/app/zap-templates/zcl/data-model/chip/onoff-cluster.xml`（集群 XML，Alchemy 生成声明）
- `matter-js/matter.js` @ `42aab0c`：
  - `packages/model/src/standard/elements/*.element.ts`（365 个生成文件，`THIS FILE IS GENERATED`）
  - `packages/model/src/standard/elements/air-purifier.element.ts`（设备类型 = Requirements）
  - `packages/model/src/standard/elements/on-off.element.ts`（conformance 表达式）
  - `packages/model/test/standard/MatterDefinitionTest.ts:45`（`elementCount >= 3582` 棘轮）
  - `support/codegen/src/mom/chip/load-chip.ts:30-50`（从 CHIP 仓库拉 XML）
- `al-one/hass-xiaomi-miot` @ `8ac4df7`：`custom_components/xiaomi_miot/core/device_customizes.py:1-60`（3957 行覆盖表）、`core/miot_specs_extend.json`（2057 行）、`core/utils.py:255-262`（通配降级）
- `merdok/homebridge-miot` @ `d27d98f`：`lib/factories/DeviceFactory.js`（147 行）、`lib/modules/custom/`
- `arendst/Tasmota`、`blakadder/templates`：`TEMPLATES.md`（位置化模板）、`_templates/*.md`（2871 页）、`templates.json`（Jekyll 生成的索引）
- `Koenkk/zigbee2mqtt` @ `3c841fd`：`lib/extension/bridge.ts:948`（exposes → 前端）、`lib/extension/homeassistant.ts:622`（exposes → HA discovery）

**本仓库**

- `Sources/MijiaCore/MiCloud/MiotSynthesizer.swift:36-80,273-340,409-474,509-583,1429-1568,1675-1775`
- `Sources/MijiaCore/MiCloud/MiotFacets.swift:284,343-410,556`
- `Sources/MijiaCore/MiotFacetText.swift:8-90,94`
- `Sources/MijiaCore/MiCloud/MiotFallbackSpec.swift:6,25-30,64-78`
- `Sources/MijiaCore/Resources/deviceProfiles.json`（281 行）、`Resources/fallbackSpecs.json`（729 行）
- `windows/src/core/miCloud/synthesis.ts:721-760,837+`、`windows/src/core/miCloud/facets.ts`、`windows/src/core/miotFacetText.ts:12,56,242,248`
- `windows/src/core/haDomains.ts`、`Sources/MijiaCore/DeviceSynthesizer.swift`
- `Tests/MijiaCoreTests/MiotCoverageBaselineTests.swift:10,30,69`
- `Tests/MijiaCoreTests/MiotFacetsTests.swift:208`、`MiotFallbackSpecTests.swift:7`
- `Tests/Fixtures/miot_coverage_golden.json`（208 specs / 177 types / 1 divergence）、`miot_golden.json`（163 KB）、`miot_facets_coverage_golden.json`
- `windows/tests/miotCoverage.test.ts:87`
- `scripts/check_capability_manifest.py:23-168`
- `Sources/MijiaCore/DeviceDeduplicator.swift:449`、`windows/src/core/dualSourceProvider.ts:539`

**文档**

- ADR-0006（双端实现 + 共享语料）、ADR-0008（双源去重）、ADR-0011（全设备覆盖 / 数据化覆盖层）、ADR-0020（后端描述表）、ADR-0023（宿主内置能力与共享清单）

---

### 摘要

1. **先把 112 条重复标题 + 4 张状态词表（约 24 条判定行）从代码搬进 `Shared/*.json`**（P0，成本 S，零语义风险），并复用 `check_capability_manifest.py` 的门禁范式建立 `check_device_rules.py`。
2. **再把"认领阶梯"（aliases/claims/builders）数据化**（P1，M）：这能直接消灭已存在的 `stb/television` 漂移，把 `windowsDivergences` 从"记录差异"变成"消灭差异"，并让 `miot_coverage_golden.json` 的 matched 从 69/208 往上走。
3. **形状谓词是覆盖率主路径但风险最高**（P1，L）：先按 ADR-0011 §1 补齐第 3 级，配"反例 fixture"再上线；全程守住 ADR-0023 的封闭性（禁止表达式求值与代码指针）与 ADR-0008 的去重胜出语料。

报告路径：`docs/research/2026-11-23-deep-dive/03-data-driven-device-definitions.md`
