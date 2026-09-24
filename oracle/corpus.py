#!/usr/bin/env python3
"""Scenario corpus: realistic chat-app screenshots WITH ground truth.

Axes covered: 1v1 vs group, light vs dark, WeChat vs QQ skin, wrapped long bubbles,
quoted replies, transfer/red-packet cards, images/stickers (must yield NO text bubble),
voice messages (duration + transcript), notification banner overlay, unread badge,
typing indicator in nav bar, system/system-time separators, device widths.

Every scenario carries the ground truth the capture pipeline is judged against, plus
the chrome strings that must never leak into a detected bubble.
"""
from html import escape

SKINS = {
    "wechat_light": dict(page="#EDEDED", nav="#EDEDED", nav_fg="#191919", nav_border="#E2E2E2",
                         them="#FFFFFF", me="#95EC69", fg="#191919", me_fg="#191919",
                         meta="#9A9A9A", field="#FFFFFF", radius=5, av_them="#4C7DE0", av_me="#39B54A"),
    "wechat_dark": dict(page="#111111", nav="#1E1E1E", nav_fg="#D8D8D8", nav_border="#2A2A2A",
                        them="#2C2C2C", me="#3EB575", fg="#D8D8D8", me_fg="#111111",
                        meta="#7A7A7A", field="#2C2C2C", radius=5, av_them="#3A5F9E", av_me="#2E8B57"),
    "qq_light": dict(page="#F2F2F2", nav="#12B7F5", nav_fg="#FFFFFF", nav_border="#0FA6DE",
                     them="#FFFFFF", me="#12B7F5", fg="#191919", me_fg="#FFFFFF",
                     meta="#9A9A9A", field="#FFFFFF", radius=8, av_them="#F0A020", av_me="#12B7F5"),
}

def bubble_html(kind, sender, text, quote, skin, scale=1, gt=None, foot="请收款"):
    """Render one message item; append the ground-truth expectation when gt is given."""
    s = SKINS[skin]
    me = sender == "me"
    side = "me" if me else "them"
    if kind == "time":
        if gt is not None: gt["chrome"].append(text)
        return f'<div class="ts">{escape(text)}</div>', None
    if kind == "system":
        if gt is not None: gt["chrome"].append(text)
        return f'<div class="ts sys">{escape(text)}</div>', None
    if kind == "image":
        if gt is not None: gt["no_text"].append((side, "image"))
        return (f'<div class="row {side}"><div class="avatar {side}"></div>'
                f'<div class="media img {side}"></div></div>'), None
    if kind == "card":
        title, amount = text, quote
        if gt is not None:
            gt["bubbles"].append(dict(sender="me" if me else sender if sender != "them" else "them",
                                      side=side, kind="card", contains=[title, amount, foot]))
        return (f'<div class="row {side}"><div class="avatar {side}"></div>'
                f'<div class="card {side}"><div class="crow"><div class="cicon"></div>'
                f'<div><div class="ctitle">{escape(title)}</div><div class="camt">{escape(amount)}</div></div></div>'
                f'<div class="cfoot">{escape(foot)}</div></div></div>'), None
    if kind == "voice":
        if gt is not None:
            gt["bubbles"].append(dict(sender="me" if me else sender if sender != "them" else "them",
                                      side=side, kind="voice", contains=[text, quote]))
        return (f'<div class="row {side}"><div class="avatar {side}"></div>'
                f'<div class="bubble vb {side}"><div class="vrow"><span class="vwave"></span>'
                f'<span class="vdur">{escape(text)}</span></div>'
                f'<div class="vtext">{escape(quote)}</div></div></div>'), None
    # text / quote
    label = ""
    sender_name = None
    if not me and sender != "them":
        sender_name = sender
        label = f'<div class="sender">{escape(sender)}</div>'
    if gt is not None:
        # In a group chat the sender name is a small grey label above the bubble. At low
        # contrast (dark mode) the recogniser may not read it at all, so "unnamed other
        # party" is an accepted outcome — label recovery is measured separately.
        gt["bubbles"].append(dict(sender="me" if me else (sender_name or "them"),
                                  sender_alt=([] if me or not sender_name else ["them"]),
                                  side=side, kind=kind, text=text,
                                  quote=quote if kind == "quote" else None))
    inner = ""
    if kind == "quote":
        inner += f'<div class="quotebox">{escape(quote)}</div>'
    inner += f'<div class="body">{escape(text)}</div>'
    if label:
        return (f'<div class="row {side}"><div class="avatar {side}"></div>'
                f'<div class="colbuf">{label}<div class="bubble {side}">{inner}</div></div></div>'), None
    return (f'<div class="row {side}"><div class="avatar {side}"></div>'
            f'<div class="bubble {side}">{inner}</div></div>'), None


def build_html(sc: dict) -> tuple[str, dict]:
    s = SKINS[sc["skin"]]
    W, H = sc["width"], sc["height"]
    gt = dict(bubbles=[], chrome=[], no_text=[])
    rows = []
    for item in sc["items"]:
        kind = item[0]
        if kind == "card":
            sender = item[1]
            title, amount = item[2]
            foot = item[3] if len(item) > 3 else "请收款"
            rows.append(bubble_html("card", sender, title, amount, sc["skin"], gt=gt, foot=foot)[0])
        elif kind == "voice":
            rows.append(bubble_html("voice", item[1], item[2], item[3], sc["skin"], gt=gt)[0])
        elif kind == "quote":
            rows.append(bubble_html("quote", item[1], item[3], item[2], sc["skin"], gt=gt)[0])
        elif kind in ("time", "system"):
            rows.append(bubble_html(kind, None, item[1], None, sc["skin"], gt=gt)[0])
        elif kind in ("image", "text"):
            sender = item[1]
            text = item[2] if len(item) > 2 else ""
            rows.append(bubble_html(kind, sender, text, None, sc["skin"], gt=gt)[0])
    nav = sc.get("nav", "")
    if nav and sc.get("chrome_nav"):
        gt["chrome"].append(nav)
    banner = ""
    if sc.get("banner"):
        gt["chrome"].append(sc["banner"][0])
        gt["chrome"].append(sc["banner"][1])
        banner = (f'<div class="banner"><div class="bicon"></div><div><div class="bapp">{escape(sc["banner"][0])}</div>'
                  f'<div class="bmsg">{escape(sc["banner"][1])}</div></div></div>')
    badge = ""
    if sc.get("badge"):
        badge = '<div class="badge">3</div>'   # unread count sitting on top of the avatar
    if sc.get("input_placeholder"):
        gt["chrome"].append(sc["input_placeholder"])
    html = f"""<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><style>
  *{{margin:0;padding:0;box-sizing:border-box}}
  html,body{{width:{W}px;height:{H}px;overflow:hidden}}
  body{{font-family:"Microsoft YaHei","PingFang SC",sans-serif;background:{s['page']};color:{s['fg']}}}
  .statusbar{{height:44px;display:flex;align-items:center;justify-content:space-between;padding:0 22px;font-size:14px;font-weight:600}}
  .navbar{{height:44px;display:flex;align-items:center;justify-content:center;border-bottom:1px solid {s['nav_border']};
           background:{s['nav']};color:{s['nav_fg']};font-size:17px;font-weight:500}}
  .chat{{height:{H-44-44-56}px;padding:14px 14px 0 14px;overflow:hidden}}
  .ts{{text-align:center;font-size:12px;color:{s['meta']};margin:12px 0}}
  .sys{{font-size:11px}}
  .row{{display:flex;margin-bottom:12px;align-items:flex-start}}
  .row.me{{flex-direction:row-reverse}}
  .avatar{{width:38px;height:38px;border-radius:{s['radius']}px;flex:0 0 38px}}
  .avatar.them{{background:{s['av_them']}}} .avatar.me{{background:{s['av_me']}}}
  .colbuf{{display:flex;flex-direction:column;align-items:flex-start;margin:0 8px;max-width:238px}}
  .sender{{font-size:11px;color:{s['meta']};margin-bottom:3px;padding-left:2px}}
  .bubble{{max-width:238px;padding:9px 12px;border-radius:{s['radius']}px;font-size:16px;line-height:1.45;word-break:break-word;margin:0 8px}}
  .colbuf .bubble{{margin:0}}
  .bubble.them{{background:{s['them']};color:{s['fg']}}}
  .bubble.me{{background:{s['me']};color:{s['me_fg']}}}
  .quotebox{{font-size:12px;line-height:1.4;color:{s['meta']};border-left:2px solid {s['meta']};padding-left:6px;margin-bottom:6px}}
  .media{{width:150px;height:112px;border-radius:{s['radius']}px;margin:0 8px;background:{s['them']}}}
  .card{{width:214px;border-radius:{s['radius']}px;margin:0 8px;background:{s['them']};color:{s['fg']};padding:10px 12px}}
  .crow{{display:flex;align-items:center;gap:9px}}
  .cicon{{width:34px;height:34px;border-radius:4px;background:#F5A623;flex:0 0 34px}}
  .ctitle{{font-size:14px;font-weight:600}} .camt{{font-size:15px;margin-top:2px}}
  .cfoot{{font-size:12px;color:{s['meta']};margin-top:8px;border-top:1px solid {s['nav_border']};padding-top:7px}}
  .vb{{min-width:120px}} .vrow{{display:flex;align-items:center;gap:8px}} .vdur{{font-size:15px}}
  .vwave{{width:14px;height:14px;border-radius:50%;border:2px solid currentColor;opacity:.5}}
  .vtext{{font-size:13px;color:{s['meta']};margin-top:5px}}
  .inputbar{{height:56px;background:{s['nav']};border-top:1px solid {s['nav_border']};display:flex;align-items:center;padding:0 14px}}
  .field{{flex:1;height:36px;background:{s['field']};border-radius:4px;display:flex;align-items:center;padding:0 10px;font-size:15px;color:{s['meta']}}}
  .banner{{position:absolute;top:52px;left:8px;right:8px;background:rgba(250,250,250,.97);border-radius:14px;padding:9px 12px;display:flex;gap:10px;box-shadow:0 2px 10px rgba(0,0,0,.18)}}
  .bicon{{width:32px;height:32px;border-radius:7px;background:#39B54A;flex:0 0 32px}}
  .bapp{{font-size:12px;color:#333;font-weight:600}} .bmsg{{font-size:13px;color:#111;margin-top:1px}}
  .badge{{position:absolute;top:0;left:44px;background:#FA5151;color:#fff;font-size:11px;padding:1px 5px;border-radius:9px}}
</style></head><body>
  <div class="statusbar"><span>{sc.get('clock','21:47')}</span><span>5G &#9679;&#9679;&#9679; 86%</span></div>
  <div class="navbar">{escape(nav)}</div>
  <div class="chat">{''.join(rows)}</div>
  {banner}
  <div class="inputbar"><div class="field">{escape(sc.get('input_placeholder','输入消息…'))}</div></div>
  {badge}
</body></html>"""
    return html, gt


SCENARIOS = [
    dict(id="s01_1v1_light_short", skin="wechat_light", width=390, height=844, nav="李经理",
         chrome_nav=True, input_placeholder="输入消息…", clock="21:47",
         items=[("time", "21:38"),
                ("text", "them", "小陈，在吗？"),
                ("text", "them", "有个急事，今晚必须处理完"),
                ("text", "me", "李经理您好，具体是什么事？"),
                ("text", "them", "你手上的活先放一放")]),

    dict(id="s02_1v1_light_wrapped", skin="wechat_light", width=390, height=844, nav="王姐",
         chrome_nav=True, input_placeholder="输入消息…",
         items=[("text", "them", "小陈，合同的事情我今天下午跟法务对过了，还有三处需要你改一下，具体是付款条款、违约责任和保密期限这三段，改完发我一份"),
                ("text", "me", "好的王姐，我今天下班前改完发您，另外付款条款那部分我想跟您确认一下时间节点的口径"),
                ("text", "them", "可以，改完我们电话过一遍")]),

    dict(id="s03_group_light", skin="wechat_light", width=390, height=844, nav="项目冲刺群(8)",
         chrome_nav=True, input_placeholder="输入消息…",
         items=[("time", "20:15"),
                ("text", "王姐", "今天的联调结果出来了"),
                ("text", "me", "我这边接口已经通了"),
                ("text", "赵工", "@小陈 帮我看下订单服务那个超时"),
                ("text", "them", "收到，我晚点看"),
                ("text", "王姐", "明天上午十点开会同步进度")]),

    dict(id="s04_1v1_dark", skin="wechat_dark", width=390, height=844, nav="李经理",
         chrome_nav=True, input_placeholder="输入消息…",
         items=[("time", "21:38"),
                ("text", "them", "能不能先帮我垫一笔款，2980，明天财务走完流程就还你"),
                ("text", "them", "走我的私人账户就行，别跟其他人说"),
                ("text", "me", "垫款的话我需要走一下审批流程")]),

    dict(id="s05_qq_light", skin="qq_light", width=390, height=844, nav="陈同学",
         chrome_nav=True, input_placeholder="输入消息…",
         items=[("text", "them", "周末那个活动你还去吗"),
                ("text", "me", "去，我周六上午到"),
                ("text", "them", "好，我在门口等你")]),

    dict(id="s06_cards_transfer", skin="wechat_light", width=390, height=844, nav="李经理",
         chrome_nav=True, input_placeholder="输入消息…",
         items=[("text", "them", "我先转给你"),
                ("card", "them", ("转账", "￥2980.00"), "请收款"),
                ("text", "me", "收到了")]),

    dict(id="s07_media_mixed", skin="wechat_light", width=390, height=844, nav="王姐",
         chrome_nav=True, input_placeholder="输入消息…",
         items=[("image", "them"),
                ("text", "them", "这是我刚拍的现场照片"),
                ("voice", "them", "12''", "转文字：明天记得把合同带过来"),
                ("text", "me", "好的")]),

    dict(id="s08_quoted_reply", skin="wechat_light", width=390, height=844, nav="李经理",
         chrome_nav=True, input_placeholder="输入消息…",
         items=[("text", "them", "你能不能今天就把方案发我"),
                ("quote", "me", "李经理：你能不能今天就把方案发我", "我今天下午六点前发您"),
                ("text", "them", "好")]),

    dict(id="s09_banner_and_badge", skin="wechat_light", width=390, height=844, nav="李经理",
         chrome_nav=True, input_placeholder="输入消息…", badge=True,
         banner=("微信", "王姐：合同改好了吗"),
         items=[("text", "them", "在忙吗"),
                ("text", "me", "在的，稍等我看一下")]),

    dict(id="s10_typing_indicator", skin="wechat_light", width=390, height=844, nav="对方正在输入…",
         chrome_nav=True, input_placeholder="输入消息…",
         items=[("system", "以下是新消息"),
                ("time", "22:01"),
                ("text", "them", "那个款项你考虑得怎么样"),
                ("text", "me", "我需要再确认一下")]),

    dict(id="s11_narrow_dark_group", skin="wechat_dark", width=375, height=812, nav="家人群(5)",
         chrome_nav=True, input_placeholder="输入消息…",
         items=[("text", "妈", "明天回来吃饭吗"),
                ("text", "me", "回，下午到"),
                ("text", "爸", "我给你留了车位"),
                ("text", "me", "谢谢爸")]),

    dict(id="s12_wide_light_long", skin="wechat_light", width=430, height=932, nav="赵工",
         chrome_nav=True, input_placeholder="输入消息…",
         items=[("text", "them", "生产环境的告警我看了，是订单服务的连接池被打满了，我先把最大连接数调高临时顶一下，明天再查泄漏点"),
                ("text", "me", "好，那我把监控面板的阈值也调一下，免得半夜又告警"),
                ("text", "them", "行")]),
]