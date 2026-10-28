# Usage details

For installation and quick setup, see the [README](../README.md#use).

## Sessions and saved preferences

Sessions get pets automatically. Each directory remembers your last character choice; additional sessions
get random characters, avoiding duplicates when possible. Change a pet in **Sessions** or its context menu.

Ended sessions disappear automatically; directory preferences remain for the next launch.
Each directory remembers every pet's position. New sessions reuse vacant positions without moving active pets;
pets outside the available screens move back to the nearest visible area.
Pets gently wobble while being dragged, while their normal animations keep playing. The wobble respects
the macOS Reduce Motion setting.
Selecting **None** hides a pet for that session without forgetting the directory's character choice.

## Appearance

The language follows the primary macOS language by default, falling back to English when unsupported.
You can also select English / 繁體中文 / 日本語 manually.
Animation duration applies to a complete loop: four frames at 1.2 seconds means 0.3 seconds per frame.
Settings apply immediately. Turn off the duration override to use each GIF's original timing.
Size is the base display size; per-character scale adjustments keep monsters visually balanced.

The **Characters** table shows each monster's EM ID. Click **ID** or **Name** to sort;
click the same heading again to reverse the order. Characters without an EM ID appear last when sorting by ID.

## Habitat

Enable **Habitat** in the manager to group pets into rooms. New pets fill vacant rooms automatically;
turn off automatic placement to move them in yourself. Drag a pet into an empty room, onto another pet
to swap positions, or outside to move out. A pet moved out stays outside until you move it back or select
**Fill vacant rooms**. Drag the header handle to move the whole habitat.
Click a room background or the handle to select the habitat; the handle's border highlights the selection.
Right-click either and choose **Move to Display** to center the whole group on the selected screen; the
same menu is available in the Habitat settings. This direct move does not use Raycast or inspect other apps.
The habitat also exposes a standard window for window-management tools; moves are propagated to its residents.
Raycast compatibility is still being verified, so use the built-in display menu if its commands have no effect.
Room backgrounds can be hidden; the handle stays visible, and rooms reappear while dragging a pet.
Room assignments and the habitat position survive restarts. Turning the habitat off restores free-placement
positions. Choose a **columns × rows** layout (for example, 4 × 2 gives eight rooms).
With **Smart resizing**, full rooms expand toward available screen space, favoring a compact layout while
keeping existing rooms in place. Drag a pet onto a dashed room outside an edge and release to add a row or
column; passing through the preview does not expand it. Drag farther away to move out. Moving the last
resident of an outer edge farther out also moves it out, rather than leaving empty rows or columns behind.
All empty outer rows and columns shrink automatically, including the original grid; interior gaps remain.
For example, four pets in the right-hand 2 × 2 corner of a 4 × 2 grid keep their positions while the two empty
left columns disappear. An empty habitat keeps one room as a drop target. The size controls show the actual
dimensions; turn smart resizing off to keep a fixed grid. Expansion stops at 8 × 8 or when no side fits the
screen; overflow pets stay outside. The habitat scales down on smaller screens, and an unplugged display returns the whole group
to a visible screen.

## Terminal focus

Double-click a pet or choose **Show Terminal** to focus its session. For native Ghostty tabs, Ghostty 1.3+
and macOS Automation permission are required. DeskPets matches the session's working directory, then its
title if several terminals share that directory. If both are ambiguous, select the tab manually.
See [Ghostty's AppleScript API](https://ghostty.org/docs/features/applescript).
For tmux inside Ghostty, DeskPets identifies the client's Ghostty tab before switching panes, then focuses
that tab. It uses the client's working directory and existing tmux terminal title; tmux settings are unchanged.
