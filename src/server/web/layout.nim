## Plain-string HTML layout shared by every server-rendered page. No
## templating engine dependency — just string building, per the project's
## "no build step" front-end philosophy.

import std/[strformat]

const sidebarLinks = [
  ("/", "Chat"),
  ("/history", "History"),
  ("/models", "Models"),
  ("/tools", "Tools"),
  ("/skills", "Skills"),
  ("/formats", "Formats"),
]

proc renderSidebar(active: string): string =
  result = "<div id=\"sidebar\"><h2>Cerisier</h2>\n"
  result.add("<a href=\"/conversations/new\" id=\"new-conversation-link\">+ New conversation</a>\n")
  for (href, label) in sidebarLinks:
    let cls = if href == active: " style=\"font-weight:bold\"" else: ""
    result.add("<a href=\"" & href & "\"" & cls & ">" & label & "</a>\n")
  result.add("</div>\n")

proc page*(title: string, active: string, bodyHtml: string, extraHead = ""): string =
  ## Renders a full page: collapsible sidebar (small nav) + main content
  ## area, which takes the large majority of the screen.
  &"""<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>{title} — Cerisier</title>
  <link rel="stylesheet" href="/static/style.css">
  <script src="/static/app.js"></script>
  {extraHead}
</head>
<body>
  <button id="sidebar-toggle" onclick="toggleSidebar()">&#9776;</button>
  {renderSidebar(active)}
  <div id="main">
    {bodyHtml}
  </div>
</body>
</html>"""
