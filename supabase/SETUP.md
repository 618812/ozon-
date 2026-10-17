# OZON 定价计算器：Supabase 配置指南

## 1. 已提交的代码

- `index.html`：接入 Supabase Auth，用户名+密码登录/注册，读取数据库中的 3 天体验期和会员状态，显示套餐与微信购买说明，并包含管理员开通面板。
- `supabase/schema.sql`：用户资料、会员、管理员角色、会员变更记录、RLS 策略和管理员开通 RPC。
- CEL V6.24 线路与售价计算逻辑保留在原页面中；此提交没有替换现有线路费率算法。

Supabase Project URL 与 Publishable key 是公开客户端配置，已放在前端；没有使用或提交 service_role 密钥。

## 2. 首次配置 Supabase

1. 打开 Supabase Dashboard，进入项目 `mrmvlvpjldosrqivufga`。
2. 在 SQL Editor 中打开并执行本仓库的 `supabase/schema.sql` 全部内容。
3. 进入 Authentication → Providers → Email，关闭 **Confirm email**。用户名登录使用内部占位地址 `<username>@ozon-pricing.invalid`，该地址不能收信；如果开启邮箱确认，注册者无法完成确认流程。
4. 在 Authentication 设置中确认允许 Email/Password 登录。
5. 先通过网站注册你自己的用户名账号，再进入 Authentication → Users 找到该账号的 UUID。
6. 回到 SQL Editor，单独执行以下 SQL，并将 UUID 替换成你自己的真实 Auth 用户 UUID：

```sql
insert into public.admin_roles(user_id)
values ('替换成你的Auth用户UUID'::uuid);
```

不要把管理员角色初始化开放给普通用户；不要把 service_role key 放到网站或公开仓库中。

## 3. 人工开通会员

1. 用户登录后，要求其提供网站用户名。
2. 你在微信核实到账。
3. 使用已初始化管理员账号登录网站。
4. 在“管理员会员管理”中找到用户名，选择月卡、季卡或年卡，点击“核验后开通”并确认。
5. 系统会将新期限从当前有效会员到期时间顺延；如果会员已过期，则从当前时间起算，并写入变更记录。

套餐：月卡 ¥9.9（1 个月）、季卡 ¥29.9（3 个月）、年卡 ¥99（12 个月）。

## 4. 用户名登录方案的限制

Supabase Auth 原生使用邮箱/手机号标识；此静态站点用内部占位邮箱把用户名映射到 Auth 用户，并由 Supabase Auth 自身处理密码。占位邮箱不能接收邮件，所以当前没有“忘记密码邮件找回”能力。若需要可靠的密码重置、用户名更改或防撞库保护，建议后续改为服务端 Edge Function 提供用户名登录与管理流程。

## 5. 重要的权限边界

当前页面根据 Supabase 返回的账号状态在前端隐藏/禁用计算器，数据库会员资料通过 RLS 保护，只有管理员 RPC 能变更会员有效期。但 CEL 计算算法仍然在浏览器的 `index.html` 中执行；熟悉开发者工具的人可能绕过前端界面限制并复制/调用本地算法。

因此这版可用于接通账号、会员记录与人工开通流程，但**不能视为防篡改的服务端计算权限控制**。如果需要强制到期后无法计算，下一步应把计算请求移到 Supabase Edge Function（保留同一套 CEL V6.24 规则），由函数在每次计算前验证登录身份与会员期限。不要在前端存放任何 service_role 密钥。
