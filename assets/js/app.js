// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/to_do"
import topbar from "../vendor/topbar"
import Sortable from "../vendor/sortable.min.js"

const Hooks = {}

Hooks.SortableTasks = {
  mounted() {
    this.sortable = new Sortable(this.el, {
      group: "tasks",
      animation: 150,
      ghostClass: "opacity-40",
      dragClass: "cursor-grabbing",
      handle: "[data-drag-handle]",
      onEnd: (evt) => {
        const toCategoryId = evt.to.dataset.categoryId
        const taskIds = Array.from(evt.to.children).map(el => el.dataset.taskId)
        this.pushEvent("reorder_tasks", {category_id: toCategoryId, task_ids: taskIds})
      }
    })
  },
  destroyed() {
    this.sortable && this.sortable.destroy()
  }
}

Hooks.SmartViewPersist = {
  mounted() {
    this.onClick = (e) => {
      const btn = e.target.closest("[data-view-set]")
      if (btn) localStorage.setItem("smart:view", btn.dataset.viewSet)
    }
    this.el.addEventListener("click", this.onClick)

    const stored = localStorage.getItem("smart:view")
    if (!stored) return
    const current = new URL(location).searchParams.get("view") === "board" ? "board" : "list"
    if (stored !== current) {
      const target = this.el.querySelector(`[data-view-set='${stored}']`)
      if (target) target.click()
    }
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  }
}

Hooks.SortableCategories = {
  mounted() {
    const scope = this.el.dataset.sortScope
    this.sortable = new Sortable(this.el, {
      animation: 150,
      ghostClass: "opacity-40",
      dragClass: "cursor-grabbing",
      handle: "[data-category-drag-handle]",
      draggable: "[data-category-id]",
      group: scope === "parent" ? "columns" : "groups",
      onEnd: (evt) => {
        const fromScope = evt.from.dataset.sortScope
        const fromScopeId = evt.from.dataset.sortScopeId
        const toScope = evt.to.dataset.sortScope
        const toScopeId = evt.to.dataset.sortScopeId
        const fromIds = Array.from(evt.from.querySelectorAll(":scope > [data-category-id]"))
          .map(el => el.dataset.categoryId)
        const toIds = Array.from(evt.to.querySelectorAll(":scope > [data-category-id]"))
          .map(el => el.dataset.categoryId)

        if (evt.from === evt.to) {
          this.pushEvent("reorder_categories", {scope: toScope, scope_id: toScopeId, category_ids: toIds})
        } else {
          this.pushEvent("move_category", {
            category_id: evt.item.dataset.categoryId,
            from_scope: fromScope,
            from_scope_id: fromScopeId,
            to_scope: toScope,
            to_scope_id: toScopeId,
            from_category_ids: fromIds,
            to_category_ids: toIds
          })
        }
      }
    })
  },
  destroyed() {
    this.sortable && this.sortable.destroy()
  }
}

document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-due-set]")
  if (!btn) return
  const form = btn.closest("form")
  if (!form) return
  const input = form.querySelector("input[name='task[due_at]']")
  if (!input) return
  const action = btn.dataset.dueSet
  if (action === "clear") {
    input.value = ""
  } else {
    const days = parseInt(action, 10)
    const d = new Date()
    d.setDate(d.getDate() + days)
    d.setHours(17, 0, 0, 0)
    const pad = (n) => String(n).padStart(2, "0")
    input.value = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
  }
  input.dispatchEvent(new Event("change", {bubbles: true}))
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

