# Tetris

## Tech stack

We should use the latest version of flutter with all the new rendering tech and use flutters renderer to render the pieces and the board.

## Controls

Swiping left-right moves the piece sideways. Tapping the right side of the screen rotates the piece 90 degrees clockwise left side is counter-clockwise. Swiping down is a locking hard drop. Holding down on the screen is a non locking soft drop. Swiping up is a hold.

## Game

This should be a classical tetris game with all features implemented. Should function like the original one.

## Rules

For the systems and terms used in these rules, refer to the page below:

https://tetris.wiki/Tetris_Guideline

### Playfield

The playfield (known as the Matrix in the guideline) is 10 cells wide and 20 cells tall, with an additional 20 cell buffer zone above the top of the playfield, usually hidden or obstructed by the field frame. If the hardware permits, a sliver of the 21st row is shown to aid players manipulate the active piece in that area.

### Super Rotation System

Super Rotation System (also known as SRS) specifies tetromino rotation and wall kicks. SRS defines 5 points of rotation, each with a different purpose.
Visual rotation - The natural rotation of a tetromino.
Right/Left wall kick - Kick off an obstruction on the right or left.
Floor kick - Kick off the floor, for when a tetromino has landed. Without kicks no rotation would be possible in some cases.
Out of right well kick - If a tetromino is in a well, it can be rotated out.
Out of left well kick - If a tetromino is in a well, it can be rotated out.
Additionally, all rotations are reversible, if one is possible, the opposite is also possible. This is what allows T-Spin Triples to exist with the "Left out of well kick". There may be an option to disable wall kicks. For later games, Initial Rotation System (IRS) may be included; IRS allows piece rotations to be made during ARE by holding a rotation button.[6]

### Tetromino starting positions

Tetrominoes appear on the 21st and 22nd rows of the playfield, centered and rounded to the left when needed. They must start with their flat side down, and move down immediately after appearing.
Recent modern games would have the spawning positions lower by one or two rows, such as tetris.com.

### Lock Down

There are three types of Lock Down defined by the guideline, Infinite Placement Lock Down (or infinity), Extended Placement Lock Down (or move reset), and Classic Lock Down (or step reset). A piece has 0.5 seconds after landing on the stack before it locks down; for games with Master mode, the lock down delay value will decrease per level when the gravity is 20G. With infinity, rotating or moving the piece will reset this timer. With move reset, this is limited to 15 moves/rotations. Finally step reset will only reset the timer if the piece moves down a row. Some games have an option to change between 2 or 3 of these modes; later games use move reset as the only mode.

### Piece preview

The piece previews, known as the Next Queue in the guideline, show the player the next pieces that will come into play. Some games have up to six previews, and some the option to change the amount. The queue can either be displayed on the right or the top of the playfield, with the next active piece being the closest to the top of the playfield. Pieces should be displayed in their starting orientations.

### Hold

Hold is a mechanism that allows the player to store the active piece in the hold queue for later use. Only one piece can be in the hold queue. If there is already a piece in the hold queue, and the player holds the active piece, they are swapped, and the piece resets at the top of the playfield, becoming the new active piece. Hold cannot be used again until the piece locks down. Some games don't have the required space to display a hold piece, or that lack the necessary amount of buttons, may skip this mechanic. The combination of hold piece and Random Generator allows the player to play forever. For later games, Initial Hold System (IHS) may be included; IHS allows the next pieces to be held instantly during ARE by holding the Hold button.

### Piece colors

Colors correspond to the shape of the tetromino.

Shape	I	J	L	O	S	Z	T
Color	light blue	dark blue	orange	yellow	green	red	magenta

### Random Generator

The Random Generator (also known as "random bag" or "7 bag") determines the sequence of tetrominoes during gameplay. One of each of the 7 tetrominoes are shuffled in a "bag", and are dealt out one by one. When the bag is empty, a new one is filled and shuffled.

### Ghost piece

The ghost piece is a player aid that allows them to preview where pieces will fall to. It is usually semi transparent or represented by an outline, and does not interact with the active piece in any way. There is sometimes an option to disable it.

### Timings

Marathon speed curve is based on that used in Tetris Worlds.
Designated soft drop speed. Details vary between guideline versions.
0.5 second lock delay when gravity is less than 20G.

### Levels

Player may only level up by clearing lines. Required lines depends on the game.

### Music

Games must include a version of Korobeiniki.

### Game over conditions

The player tops out when a piece is spawned overlapping at least one block, a piece locks completely above the visible portion of the playfield, or a block is pushed above the 20-row buffer zone.

### Scoring

Scoring system, including Back-to-Back recognition rules
Combo recognition
Perfect clear recognition (for later games)

