<p align="center"><img src="docs/logo/logo.png" alt="Partner Panel logo, two people under a heart, in coral halftone dots" width="200"></p>

# Partner Panel

*Link up with your favourite person in WoW Forever and see each other at a glance.*

Partner Panel is a small addon for two people who play together: a couple, two best friends, or a veteran and the brand-new player they have somehow talked into all of this. You link up once, and from then on each of you has a little card on your screen that shows where the other one is and how they are doing.

I built it because I am new to World of Warcraft and my partner has been playing for about twenty years, which means a surprising amount of our time together used to go into one question, "where are you?" Partner Panel answers it for us, so we can get back to the part where we actually play.

---

## What it does

### The panel
The panel is a small card you can drag anywhere on your screen, and this little guy takes his job very seriously. He shows you:

- **Your partner's name and level,** in their class colour
- **Where they are,** down to the subzone (*Westfall, Sentinel Hill*)
- **What they are up to:** online, AFK, busy, in combat, resting, dead, or a ghost, which is dead with better posture
- **Their health,** as a bar that politely steps aside during combat, because WoW Forever keeps some combat details private from addons
- **Where you last saw them,** once they log off or wander out of your group (*Last seen in Westfall, 5m ago*)

### Moods
`/partner mood` leaves a short message on your partner's card, up to 60 characters, and it stays there until you change it. Use it for *"brb, snacks,"* *"come find me,"* or *"I have made a terrible mistake in this cave."*

### Linking
Group up, type `/partner link`, and your partner gets a popup asking whether they would like to link with you. It is a very polite popup. Your link is remembered after that, grouped or not, and the card goes live on its own whenever the two of you are in a group together (more on that in [Your link and the live connection](#your-link-and-the-live-connection)).

### Demo mode
If your partner has not installed it yet, `/partner demo` shows a pretend partner, a level 12 paladin who wanders from Goldshire to Duskwood, dies there roughly every twenty seconds, and against all odds gains a level each time. It lets you see the card working on your own.

---

## Getting started

1. **Both of you** install Partner Panel.
2. **Group up** with each other.
3. One of you types **`/partner link`**, and the other clicks **Accept**.

The card appears near the top left of your screen. Drag it wherever you like, then type `/partner lock` to keep it there.

---

## Your link and the live connection

These are two different parts of Partner Panel, and only one of them needs a group.

**Your link is remembered all the time.** Once you have linked, Partner Panel saves it for that character, and it stays saved whether you are grouped or not, through logging out, and through restarting the game. The card stays on your screen with your partner's name on it, and you only need to link again if one of you types `/partner unlink`.

**Live updates need a group.** Your partner's zone, status, health and mood only change on your card while your two copies of Partner Panel can send each other messages, and on WoW Forever that only happens over the group channel. When you are not grouped, the card keeps the last update it heard, *Last seen in Westfall, 5m ago*, a bit like a photo on the fridge. As soon as you group up again, it reconnects on its own within a few seconds.

**This part is about to get better.** The next update keeps the card live when you are not grouped, as long as the two of you are Battle.net friends. See [What is coming next](#what-is-coming-next).

**Linking by name is for when the short version cannot guess.** Plain `/partner link` works out who you mean from your target, or from the one other person in a two-person party. In a bigger party or a raid, it cannot tell which person you mean, so type their whole name instead, `/partner link First Last`. Either way, you still need to be in a group together for the request to reach them.

---

## Commands

| Command | What it does |
| --- | --- |
| `/partner link` | Links you with your partner while you are grouped. With no name, it uses your target, or the one other person in your party. In a bigger group, type their name: `/partner link First Last`. |
| `/partner unlink` | Undoes the link |
| `/partner mood <text>` | Sets the short message your partner sees. `/partner mood` on its own clears it. |
| `/partner show` and `/partner hide` | Shows or hides the card |
| `/partner lock` and `/partner unlock` | Pins the card in place, or lets you drag it again |
| `/partner reset` | Puts the card back in its starting spot |
| `/partner demo` | Shows the card with a pretend partner |
| `/partner status` | Shows the connection details, for when something is not working |
| `/partner` | Lists every command |

`/partnerpanel` works too, for anyone who enjoys typing.

---

## How it works

Your copy of Partner Panel and your partner's copy send each other small, hidden addon messages, so you can see how they are doing and they can see how you are doing.

- **For now, live updates travel through your group.** On WoW Forever, addon messages travel over the group channel, and addon whispers between players do not currently arrive, so the group is the room where your two copies can talk. Your link itself never needs the group, only the live updates do. When you are not grouped, the card shows where and when you last saw your partner. If Blizzard ever lets addon whispers through, Partner Panel already tries them, so the card would start updating outside a group without anyone changing a setting.
- **Only your partner reads your messages.** Each one is addressed to them by name, and anyone else in the group running Partner Panel quietly ignores it.
- **This is everything it shares:** your level, class, zone and subzone, your status (AFK, in combat, and so on), your health as a percentage (never during combat), and your mood.
- **Nothing leaves the game.** There are no websites, no accounts, no tracking, and nothing to sign up for. Your link and settings live in your own WoW folder, one character at a time.
- **It waits its turn in combat.** WoW sometimes holds addon messages at the door during a fight. Partner Panel waits, and everything goes through once the fight is over, without flooding your chat.

---

## Who it is for

- **A new player and a veteran.** The veteran can see where the new player is, and whether they are in trouble, without asking every five minutes.
- **Couples and duos levelling together,** even when you are questing in different corners of the same zone.
- **Keeping each other company** while you each run your own errands in the same group, whether that is fishing, crafting, farming, or staring at the auction house.

---

## What is coming next

Partner Panel is very new, and it has plans.

- **Live updates when you are not grouped:** if the two of you are Battle.net friends, your cards will stay live even when you are apart, so one of you can be off in a raid with other people and the other can still see where they are and what their mood says. It all happens behind the scenes, with nothing new to type and nothing to set up. Your group stays the first choice whenever you are in one together, and Battle.net quietly takes over when you are not.
- **"Should I keep this?":** shift-click an item to ask your partner about it. They answer Equip, Sell, Keep, or Bank, and their answer stays on the item's tooltip, so nobody has to ask about the same grey sword twice.
- **"Come here" ping:** your partner drops a waypoint, and an arrow on your map and screen points you to it.
- **Adventure journal:** it quietly remembers your firsts together, your first dungeon, your first boss, every new zone, with timestamps and screenshots. A small scrapbook of the two of you.
- **Tip cards:** your partner writes tips ahead of time, and they appear for you at the right moment, when you walk into a zone or a dungeon, or reach a certain level. It is like having them on your shoulder, even when they are off making dinner.

---

## Good to know

- Both of you need Partner Panel installed.
- Your link is saved all the time, but for now, live updates, and linking in the first place, need you to be in a group together. Live updates outside a group are coming next, for Battle.net friends.
- Links are per character, so link again on each character you play together.

---

## Feedback

If something breaks, or you have an idea, open an issue on [GitHub](https://github.com/soalverse/PartnerPanel/issues). If there is an error, the text from [BugSack](https://www.curseforge.com/wow/addons/bugsack) helps me find the problem much faster.

Made with care by Soalverse.
