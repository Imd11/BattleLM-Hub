# BattleLM Discord Server Operations Manual

> **Version:** 1.0  
> **Last Updated:** February 2, 2026  
> **Server Name:** BattleLM  
> **Purpose:** Community hub for BattleLM app users and developers

---

## 📋 Server Structure

```
BattleLM
│
├── ☑️ rules                    ← Rules Screening (standalone)
├── 📢 announcements            ← Announcement channel (standalone)
├── #  moderator-only           ← Staff-only, hidden from members
│
├── 📁 COMMUNITY
│   ├── #  general              ← Main chat
│   ├── #  support              ← Bug reports & troubleshooting
│   ├── #  feedback             ← Feature requests & suggestions
│   ├── #  中文                  ← Chinese language chat
│   └── #  日本語                ← Japanese language chat
│
└── 📁 VOICE CHANNELS
    └── 🔊 Lounge               ← Voice hangout
```

---

## 📝 Channel Purposes

| Channel | Purpose | Who Can Post |
|:--------|:--------|:-------------|
| `rules` | Community guidelines | Admin only |
| `announcements` | Version releases, important updates | Admin only |
| `moderator-only` | Staff discussions (hidden) | Moderators+ |
| `general` | Daily chat, questions, discussions | Everyone |
| `support` | Bug reports, technical issues | Everyone |
| `feedback` | Feature requests, suggestions | Everyone |
| `中文` | Chinese language discussions | Everyone |
| `日本語` | Japanese language discussions | Everyone |
| `Lounge` | Voice chat | Everyone |

---

## 👑 Roles Hierarchy

| Role | Permissions | Color |
|:-----|:------------|:------|
| Admin | Full control | — |
| Moderator | Manage messages, kick, mute | — |
| Member | Read & send messages | — |

---

## 📢 Content Templates

### Announcement Template (New Release)

```markdown
# 🚀 BattleLM v1.x.x Released!

**What's New:**
- Feature 1
- Feature 2
- Bug fix

**Download:** [Link]

**Full Changelog:** [Link]
```

### Announcement Template (Maintenance)

```markdown
# 🔧 Scheduled Maintenance

**When:** [Date & Time UTC]
**Duration:** ~X hours
**Impact:** [What will be affected]

We'll update you when it's complete!
```

---

## 🛠️ Daily Operations

### Moderation Checklist

- [ ] Check `#support` for unanswered questions
- [ ] Review `#feedback` for popular requests
- [ ] Remove spam/inappropriate content
- [ ] Welcome new members (optional)

### Weekly Tasks

- [ ] Post update in `#announcements` (if any)
- [ ] Review and respond to feedback
- [ ] Check server insights for growth

---

## 🤖 AI Operations Guide

> This section is for AI assistants helping manage this server.

### Context for AI

- **Product:** BattleLM is a macOS app that orchestrates multiple AI agents into a "Council"
- **iOS Companion:** Remote control/mirror app for iPhone
- **Target Audience:** Developers, AI enthusiasts, power users
- **Language:** English-first, with Chinese and Japanese channels

### Common Support Issues

1. **Pairing stuck at "Verifying Identity"**
   - Known issue with timeout/error handling
   - Direct to GitHub issues for tracking

2. **Cloudflare Tunnel not working**
   - Check if `cloudflared` is installed
   - Verify network connectivity

3. **AI providers not responding**
   - Check API key configuration
   - Verify provider status

### Response Guidelines

- Be helpful and patient
- Use English in main channels
- Link to documentation when available
- Escalate complex issues to `#moderator-only`

### Posting Permissions

| Action | AI Can Do? |
|:-------|:-----------|
| Answer questions in `#support` | ✅ Yes |
| Post announcements | ❌ No (Admin only) |
| Moderate content | ⚠️ Flag only, no action |
| Create events | ❌ No |

---

## 📊 Server Settings Reference

### Key Settings Location

| Setting | Path |
|:--------|:-----|
| Rules | Server Settings → Safety Setup → Rules Screening |
| Permissions | Channel → Edit → Permissions |
| Roles | Server Settings → Roles |
| Moderation | Server Settings → Safety Setup → AutoMod |

### Recommended AutoMod Rules

- Block spam content
- Block mention spam (>5 mentions)
- Block suspicious links (optional)

---

## 📈 Growth Tips

1. **Share invite link** in app's GitHub README
2. **Add Discord button** to app's About/Help section
3. **Cross-promote** on Twitter/X when releasing updates
4. **Engage** with community questions promptly

---

## 🔗 Quick Reference

- **Invite Link:** `[Generate from Server Settings → Invite]`
- **GitHub:** `https://github.com/[your-repo]/BattleLM`
- **Website:** `[If applicable]`

---

## 📝 Changelog

| Date | Change |
|:-----|:-------|
| 2026-02-02 | Initial setup with COMMUNITY, VOICE CHANNELS, and language channels |

---

*This manual should be updated whenever the server structure changes.*
