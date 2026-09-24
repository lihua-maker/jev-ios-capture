#!/usr/bin/env python3
"""Capture stage: OCR lines -> chrome removal -> sender labels -> bubbles (+quote split).

Engine-agnostic reference implementation of what the iOS Swift port must do: the text
recogniser only supplies line boxes + text (Windows OCR here; Apple Vision
VNRecognizeTextRequest on iOS), everything else is geometry, so the rules transfer.

Verified rules (see PHASE0_REPORT.md / corpus_report.json for the measurements):
  * vertical chrome is measured in WIDTH units, not height units. The status bar (44pt) and
    nav bar (44pt) end at 88pt; on any iPhone W is 320..440pt, so 88pt ~= 0.226*W. Using a
    fraction of H silently eats the first chat line on taller devices (found on 430x932).
  * a single CJK glyph is a perfectly good message ("行"), so a stray-token filter must key
    on glyph-shape + tiny box, never on text length alone.
  * sender name labels (group chats) sit ABOVE their bubble with a gap up to ~1.2 line heights.
  * font size is estimated from per-character advance width, not ink height: full-width
    punctuation inflates the ink box until a 12pt quote line measures taller than 16pt body.
"""
import json, unicodedata, difflib
from pathlib import Path

PUNCT = "，。？、！…：:;；·.．,'’‘\"″“”"
STRIP = "".join(ch for ch in PUNCT if ch not in "：:")
GLYPHS = set("0OoQ●○·.,-—~|[](){}<>「」/\\")

def norm(s):
    s = unicodedata.normalize("NFKC", s)
    return "".join(ch for ch in s if not ch.isspace() and ch not in STRIP)

def weight(t):
    """Per-character advance weight: CJK/full-width ~1.0, Latin/digit ~0.55."""
    return sum(0.55 if ord(ch) < 0x2E80 else 1.0 for ch in t) or 1.0

def gap_threshold(gaps, med_h):
    """Split consecutive-line gaps into 'same bubble' vs 'new bubble' adaptively.

    A fixed multiple of med_h cannot work across recognisers: Apple Vision reports ink boxes
    ~25% taller than Windows OCR for the same text, which inflates med_h and swallows real
    inter-bubble gaps that are only ~2 font-heights. The gap distribution on a chat screen is
    bimodal (in-bubble line pitch vs between-bubble margin), so find the largest relative jump
    between consecutive sorted gaps and cut there. Falls back to 1.2*med_h when the
    distribution is unimodal (e.g. every bubble is a single line).
    """
    g = sorted(x for x in gaps if x >= 0)
    thresh = None
    if len(g) >= 3:
        best_ratio, best_i = 1.0, None
        for i in range(len(g) - 1):
            ratio = (g[i + 1] + 1) / (g[i] + 1)
            if ratio > best_ratio:
                best_ratio, best_i = ratio, i
        if best_i is not None and best_ratio >= 1.4:
            thresh = (g[best_i] + g[best_i + 1]) / 2
    if thresh is None:
        thresh = 1.2 * med_h
    return min(max(thresh, 0.5 * med_h), 2.6 * med_h)

def advance(ln):
    return ln["w"] / weight(ln["text"])

def secondary_threshold(body_adv, W):
    """Where to cut between body text and the apps' secondary text (timestamps, notices, quotes).

    A constant 0.85 says "secondary text is at least 15% smaller than body", which only holds at the
    default type size. It is false the moment the body shrinks: a 12px timestamp over a 14px body
    measures 0.857 and escaped the filter, so "21:38" and quote blocks became messages at 14px.

    The body size in CSS px is recoverable from the image — advance/W is scale-invariant, and this
    codebase's chrome geometry already assumes the 390pt-wide reference device the 0.226*W band was
    measured on — so the cut is placed at the MIDPOINT between the measured body size and the
    secondary size the apps use (0.75 x the 16px default = 12px). At the default size that yields
    ~0.89; at a 14px body ~0.93, which is what lets the 12px line be recognised as secondary again.
    Clamped so a wrong body estimate can neither disable the rule nor swallow body text.
    """
    if not body_adv or not W:
        return 0.85
    body_px = body_adv * 390.0 / W
    if body_px <= 1:
        return 0.85
    return min(0.93, max(0.80, (1.0 + 12.0 / body_px) / 2.0))

def body_advance(lines):
    """Median advance of the lines that are certainly body text (>= 4 characters).

    Used to decide "is this line smaller than body text?" without trusting a global ink-height
    median, which mixes nav bars, sender labels, timestamps and chat text, and shifts with the
    renderer (measured: the same 12pt separator measures 0.73 of the median under Windows OCR and
    0.89 under Apple Vision after a font change, so a ratio threshold on that quantity is a coin
    flip). The RATIO OF ADVANCES between lines of one image is stable across both.
    """
    advs = sorted(advance(l) for l in lines if len(norm(l["text"])) >= 4)
    if not advs:
        return 0.0
    # 75th percentile, not the median: a screen with only one or two body lines and several small
    # ones drags a median down far enough to unset the threshold it feeds (measured on a synthetic
    # 3-line screen: median 40 vs divider 34.2, which is a 0.85 ratio of 34.0 — a 0.2px miss).
    return advs[min(len(advs) - 1, round(0.75 * (len(advs) - 1)))]

def levenshtein(a, b):
    if len(a) < len(b): a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]

def bigrams(s):
    return [s[i:i + 2] for i in range(len(s) - 1)] or [s]

def approx_contains(sub, text, thresh=0.8):
    a, b = norm(sub), norm(text)
    if not a: return True
    if a in b: return True
    if len(a) <= 2: return a in b
    grams = bigrams(a)
    return sum(1 for g in grams if g in b) / len(grams) >= thresh


def labelish(ln, nxt, W=None, med_h=None):
    """Would this line be read as a group-chat sender label for the line below it?

    Used BEFORE the banner filter: a banner's text starts ~0.137*W and a sender label ~0.146*W, so
    the two are 1% apart in x and only the label's structure separates them. At an 18px body the
    label box drifted to x=171 against a 175.5 cutoff and was deleted as a banner, taking two of
    three sender names with it.
    """
    if nxt is None:
        return False
    gap = nxt["y"] - (ln["y"] + ln["h"])
    return (ln["h"] < 0.85 * nxt["h"] and abs(ln["x"] - nxt["x"]) < 0.07 * (W or 0)
            and gap > -0.35 * (med_h or 0) and gap < 1.45 * (med_h or 0)
            and (ln["x"] + ln["w"] / 2) < (W or 0) / 2 and ln["w"] < 0.4 * (W or 0)
            and len(norm(ln["text"])) <= 8)

def segment(doc):
    W, H = doc["width"], doc["height"]
    lines = sorted(doc["lines"], key=lambda l: l["y"])
    dropped, kept = [], []
    if not lines:
        return [], dropped, (W, H)
    med_h = sorted(l["h"] for l in lines)[len(lines) // 2]
    body_adv = body_advance(lines)
    sec = secondary_threshold(body_adv, W)

    index_of = {id(l): i for i, l in enumerate(lines)}

    def nxt_of(ln):
        i = index_of.get(id(ln))
        return lines[i + 1] if i is not None and i + 1 < len(lines) else None

    for ln in lines:
        cx, cy = ln["x"] + ln["w"] / 2, ln["y"] + ln["h"] / 2
        t, tn = ln["text"], norm(ln["text"])
        if cy < 0.226 * W:                       # status bar + nav bar + notification banner
            dropped.append(("statusbar_nav_banner", t)); continue
        # A notification banner (or any overlay card) in the top third insets its text LEFT of
        # the message rail: bubbles never start left of ~0.16*W, banner text starts at ~0.13*W.
        # Needed because Vision reads banners that other recognisers miss, and a banner can sit
        # lower than the 88pt nav band (measured: text centre at 0.2266*W, 1px past the cutoff).
        if cy < 0.30 * H and ln["x"] < 0.15 * W and not labelish(ln, nxt_of(ln), W, med_h):
            dropped.append(("banner_overlay", t)); continue
        if cy > H - 0.235 * W:                   # input bar (+ home indicator safe area)
            dropped.append(("inputbar", t)); continue
        # Centred system lines: 21:38 / 以下是新消息 / 撤回提示. The discriminator is GEOMETRY, not
        # size. Measured over both renderers, genuine centred lines sit within 0.0021*W of the screen
        # centre while the closest small line INSIDE a bubble sits at 0.0479*W — a 23x gap, so a
        # 0.02*W bound has ~9x margin either side. Size was the old discriminator and it flipped
        # 0.73 -> 0.89 across a font change, which is how a divider grew into a bubble. The width
        # bound excludes a wide wrapped bubble whose ink centre lands near the middle (a 0.52*W
        # left-anchored bubble measures 0.44*W); the advance is only a safety condition.
        if (abs(cx - W / 2) < 0.02 * W and ln["w"] < 0.45 * W
                and body_adv and advance(ln) < sec * body_adv):
            dropped.append(("timesep_or_system", t)); continue
        # icon/badge hallucination: glyph-shaped or a tiny box hugging the avatar column
        glyphish = tn and all(ch in GLYPHS for ch in tn)
        tiny_badge = len(tn) <= 2 and ln["h"] <= 0.8 * med_h and ln["w"] <= 0.06 * W
        near_rail = ln["x"] < 0.135 * W or (ln["x"] + ln["w"]) > 0.865 * W
        if near_rail and (glyphish or (tiny_badge and ln["h"] < 0.9 * med_h)):
            dropped.append(("icon_or_badge", t)); continue
        kept.append(ln)

    if not kept:
        return [], dropped, (W, H)
    med_h = sorted(l["h"] for l in kept)[len(kept) // 2]

    # sender labels: small, short, left-aligned with the bubble directly beneath (gap <= ~1.2 lines)
    # sender labels: small, short, left-aligned with the bubble directly beneath (gap <= ~1.2 lines).
    # The advance margin is the only thing separating an 11pt name label from a 14pt card title over
    # a 15pt amount: measured label ratios are 0.74-0.85, the card title sits at 0.93, so 0.88 keeps
    # both sides of that gap. A per-app adapter would make this explicit instead of inferred.
    labels, used = {}, set()
    for i, ln in enumerate(kept[:-1]):
        nxt = kept[i + 1]
        gap = nxt["y"] - (ln["y"] + ln["h"])
        if (ln["h"] < 0.85 * nxt["h"] and abs(ln["x"] - nxt["x"]) < 0.07 * W
                and gap > -0.35 * med_h and gap < 1.45 * med_h and (ln["x"] + ln["w"] / 2) < W / 2
                and ln["w"] < 0.4 * W and len(norm(ln["text"])) <= 8):
            labels[i + 1] = ln["text"]; used.add(i)
    bubbles, cur = [], None
    clusterable = [ln for i, ln in enumerate(kept) if i not in used]
    gaps, prev = [], None
    for ln in clusterable:
        side = "them" if (ln["x"] + ln["w"] / 2) < W / 2 else "me"
        if prev is not None and prev[0] == side:
            gaps.append(ln["y"] - (prev[1]["y"] + prev[1]["h"]))
        prev = (side, ln)
    split = gap_threshold(gaps, med_h)

    for i, ln in enumerate(kept):
        if i in used: continue
        cx = ln["x"] + ln["w"] / 2
        side = "them" if cx < W / 2 else "me"
        # A WRAPPED CONTINUATION LINE of a right-aligned bubble can put its ink centre left of the
        # screen centre: the bubble is right-anchored, so a last line that wrapped short is inset on
        # the right and its centre drifts left (measured at 14px body: a 462px line inside a 629px
        # bubble centres at 0.036*W left of the middle and was attributed to the other person, which
        # is the error that makes the model describe the user's own words as the counterparty's).
        # Inherit the open bubble's side when the line is BOTH ambiguous about the centre AND
        # horizontally co-extensive with what is already open. Both conditions are needed: a genuine
        # wide bubble on the other side is near the centre too, but overlaps the open one by only
        # ~0.55 of its width, while a continuation line overlaps by ~1.0.
        if cur and cur["side"] == "me" and (ln["y"] - (cur["y0"] + cur["h0"])) < 0.95 * med_h:
                if (abs(ln["x"] - cur["x0"]) < 0.03 * W
                        or abs((ln["x"] + ln["w"]) - cur["x1"]) < 0.03 * W):
                    side = cur["side"]
        if cur and cur["side"] == side:
            gap = ln["y"] - (cur["y0"] + cur["h0"])
            xov = min(cur["x1"], ln["x"] + ln["w"]) - max(cur["x0"], ln["x"])
            # a continuation line that starts well LEFT of the block's current left edge is the
            # inner footer of a card (icon pushes its title right) — accept a larger gap for it
            # The card-footer branch is about a bubble's inner layout, so it only applies to a
            # line that is on the message rail at all. Guard the lower bound: at an 18px body
            # Vision merged one message's box with the avatar column (x=0, a two-line-tall box),
            # and without the guard that line looked like a card footer and swallowed the bubble
            # above it. A real card footer starts at ~0.185*W.
            indented = ((cur["x0"] - ln["x"]) > 0.04 * W and ln["x"] > 0.15 * W)
            if (gap < split or (indented and gap < 2.2 * med_h)) and xov > -0.5 * min(cur["w"], ln["w"]):
                cur["lines"].append(ln); cur["y0"] = ln["y"]; cur["h0"] = ln["h"]
                cur["x0"] = min(cur["x0"], ln["x"]); cur["x1"] = max(cur["x1"], ln["x"] + ln["w"])
                cur["w"] = cur["x1"] - cur["x0"]
                continue
        cur = dict(side=side, lines=[ln], x0=ln["x"], x1=ln["x"] + ln["w"], y0=ln["y"],
                   h0=ln["h"], w=ln["w"], y=ln["y"], label=labels.get(i))
        bubbles.append(cur)

    # post-pass: a wrapped trailing fragment of a right-aligned bubble can measure its centre on
    # the LEFT half of the screen (Vision split "…审批流程" into "…审批流" + a lone "程" at
    # x=307,w=58) and would otherwise become a bubble attributed to the other side. Absorb such a
    # lone short line into the bubble directly above when their left edges match.
    absorbed = []
    for b in bubbles:
        prev = absorbed[-1] if absorbed else None
        lone = len(b["lines"]) == 1 and len(norm(b["lines"][0]["text"])) <= 3
        if (lone and prev is not None and prev["side"] != b["side"]
                and abs(b["x0"] - prev["x0"]) < 0.02 * W
                and 0 <= b["y0"] - (prev["y0"] + prev["h0"]) < 2.2 * med_h):
            prev["lines"] += b["lines"]
            prev["y0"], prev["h0"] = b["y0"], b["h0"]
            prev["x0"] = min(prev["x0"], b["x0"]); prev["x1"] = max(prev["x1"], b["x1"])
            prev["w"] = prev["x1"] - prev["x0"]
            continue
        absorbed.append(b)
    bubbles = absorbed

    out = []
    for b in bubbles:
        b["lines"].sort(key=lambda l: (l["y"], l["x"]))
        lines = b["lines"]
        # font size from the MEDIAN advance of multi-character lines: a single-character line's
        # box carries too much padding (Vision reported a 58.5px advance for a lone 你), and a
        # max would be just as distorted.
        multi = sorted(advance(l) for l in lines if len(norm(l["text"])) >= 2)
        body_adv = multi[len(multi) // 2] if multi else max(advance(l) for l in lines)
        small_idx = [i for i, l in enumerate(lines)
                     if len(norm(l["text"])) >= 2
                     and advance(l) < secondary_threshold(body_adv, W) * body_adv]
        big_idx = [i for i in range(len(lines)) if i not in small_idx]
        # a secondary-font block counts as a quote only when it PRECEDES the body; a card footer
        # or a voice transcript AFTER the body is part of the body
        if small_idx and big_idx and min(small_idx) > max(big_idx):
            big_idx, small_idx = big_idx + small_idx, []
        out.append(dict(side=b["side"],
                        sender=b["label"] or ("me" if b["side"] == "me" else "them"),
                        y=round(b["y"], 1),
                        text="".join(lines[i]["text"] for i in big_idx),
                        quote="".join(lines[i]["text"] for i in small_idx),
                        raw_lines=[l["text"] for l in lines]))
    return out, dropped, (W, H)


def expected_senders(g):
    return [g["sender"]] + list(g.get("sender_alt", []))


def evaluate(ocr_doc, gt):
    """Two verdicts, deliberately separated:
      ok    = the PIPELINE (chrome removal, clustering, attribution, quote split) is correct
      clean = ok AND the text recogniser missed nothing (no engine recall gap)
    Recogniser character errors are reported as `deltas` and folded into char_accuracy
    (gate: >= 0.95), because no on-device recogniser is character-perfect.
    """
    bubbles, dropped, (W, H) = segment(ocr_doc)
    gt_b = gt["bubbles"]
    all_text = "".join(b["text"] + b["quote"] for b in bubbles)
    recall_misses, effective = [], []
    for g in gt_b:
        exp = g.get("text") or g.get("quote") or ""
        if exp and not approx_contains(exp, all_text):
            recall_misses.append(dict(sender=g["sender"], gt=exp))
        else:
            effective.append(g)

    fails, deltas = [], []
    if len(bubbles) != len(effective):
        fails.append(f"bubble count {len(bubbles)} != expected {len(effective)} "
                     f"({len(recall_misses)} engine recall miss must be excluded)")
    sims = {k: [] for k in ("text", "quote")}
    totals = [0, 0]
    sender_ok, label_expected, label_recovered = 0, 0, 0
    for i, g in enumerate(effective):
        if g.get("sender_alt"):
            label_expected += 1
        got = bubbles[i] if i < len(bubbles) else None
        if got is None:
            totals[0] += len(norm(g.get("text") or "")); totals[1] += len(norm(g.get("text") or ""))
            continue
        if got["sender"] in expected_senders(g):
            sender_ok += 1
            if g.get("sender_alt") and got["sender"] == g["sender"]:
                label_recovered += 1
        else:
            fails.append(f"[{i}] sender {got['sender']!r} != {g['sender']!r} (text={got['text'][:18]!r})")
        combined = got["text"] + got["quote"]
        if g.get("contains"):
            for sub in g["contains"]:
                if not approx_contains(sub, combined):
                    fails.append(f"[{i}] missing {sub!r} in {combined!r}")
            continue
        exp_text, exp_quote = g.get("text", "") or "", g.get("quote", "") or ""
        if g["kind"] == "quote":
            sims["quote"].append(difflib.SequenceMatcher(None, norm(exp_quote), norm(got["quote"])).ratio())
            if not got["quote"]:
                fails.append(f"[{i}] quote block not separated from body")
        a, b = norm(exp_text), norm(got["text"])
        sims["text"].append(difflib.SequenceMatcher(None, a, b).ratio())
        totals[0] += len(a); totals[1] += levenshtein(a, b)
        if a != b:
            deltas.append(f"[{i}] recognition: GT={exp_text!r} OCR={got['text']!r}")
    gt_all = "".join(norm(g.get("text") or "") + norm(g.get("quote") or "")
                     + "".join(norm(c) for c in g.get("contains", [])) for g in gt_b)
    leaked = []
    for c in gt["chrome"]:
        nc = norm(c)
        if not nc: continue
        for b in bubbles:
            if nc == norm(b["text"]) or nc == norm(b["quote"]):
                leaked.append(f"chrome {c!r} became a whole bubble"); break
            if any(nc == norm(rl) and nc not in gt_all for rl in b["raw_lines"]):
                leaked.append(f"chrome {c!r} leaked into a bubble line"); break
    fails += leaked
    acc = round(max(0.0, 1 - totals[1] / max(totals[0], 1)), 4)   # over-merge can push this negative
    ok = (not fails) and acc >= 0.95
    return dict(bubbles=len(bubbles), expected=len(gt_b), effective=len(effective),
                count_ok=len(bubbles) == len(effective),
                sender_ok=f"{sender_ok}/{len(effective)}",
                sender_labels=f"{label_recovered}/{label_expected}" if label_expected else None,
                char_accuracy=acc,
                mean_sim=round(sum(sims["text"]) / len(sims["text"]), 4) if sims["text"] else None,
                quote_sim=round(sum(sims["quote"]) / len(sims["quote"]), 4) if sims["quote"] else None,
                chrome_leaks=len(leaked), icon_hallucinations=sum(1 for r, _ in dropped if r == "icon_or_badge"),
                recall_misses=recall_misses,
                dropped=dropped, detected=[dict(sender=b["sender"], text=b["text"], quote=b["quote"]) for b in bubbles],
                fails=fails, deltas=deltas, ok=ok, clean=ok and not recall_misses)


if __name__ == "__main__":
    d = json.loads(Path(__file__).with_name("ocr_3x.json").read_text(encoding="utf-8"))
    out, dropped, wh = segment(d)
    print(json.dumps(dict(bubbles=out, dropped=dropped), ensure_ascii=False, indent=2))