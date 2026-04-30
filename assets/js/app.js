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
import Cropper from "../vendor/cropper.min.js"
import "../vendor/cropper.min.css"

const Hooks = {}

// AvatarCropper: drives the crop flow when a user picks an image.
//
// HEEx structure expected:
//   <div id="avatar-cropper" phx-hook="AvatarCropper">
//     <form phx-change="validate_avatar">
//       <input type="file" name="avatar" data-cropper-output ... />  (live_file_input)
//     </form>
//     <input type="file" data-cropper-input ... />
//     <div data-cropper-stage hidden>
//       <img data-cropper-image />
//       <button data-cropper-cancel />
//       <button data-cropper-save />
//     </div>
//   </div>
//
// On file pick: load into <img>, instantiate Cropper with a square aspect
// ratio, show the stage. On Save: getCroppedCanvas().toBlob → DataTransfer
// → assign to the LiveView upload input → fire `change` (and `input`) so
// LV's auto-upload picks the file up.
Hooks.AvatarCropper = {
  mounted() {
    this.input = this.el.querySelector("[data-cropper-input]")
    this.stage = this.el.querySelector("[data-cropper-stage]")
    this.image = this.el.querySelector("[data-cropper-image]")
    this.cancelBtn = this.el.querySelector("[data-cropper-cancel]")
    this.saveBtn = this.el.querySelector("[data-cropper-save]")

    this.onPick = (e) => {
      const file = e.target.files[0]
      if (!file) return
      const url = URL.createObjectURL(file)
      this.image.src = url
      this.stage.hidden = false
      this.image.onload = () => {
        if (this.cropper) this.cropper.destroy()
        this.cropper = new Cropper(this.image, {
          aspectRatio: 1,
          viewMode: 1,
          // Start with the crop box at 80% so the difference between
          // "selected region" and "rest of image" is obvious.
          autoCropArea: 0.8,
          // Drag-mode "move" lets the user pan the *image* under the crop
          // box; the box itself stays draggable/resizable via its handles.
          dragMode: "move",
          movable: true,
          zoomable: true,
          zoomOnWheel: true,
          zoomOnTouch: true,
          cropBoxMovable: true,
          cropBoxResizable: true,
          toggleDragModeOnDblclick: false,
          responsive: true,
          background: false,
          rotatable: false,
          scalable: false,
        })
      }
    }

    this.onCancel = () => this.reset()

    this.onSave = () => {
      if (!this.cropper) return
      this.cropper.getCroppedCanvas({
        width: 256,
        height: 256,
        imageSmoothingQuality: "high"
      }).toBlob((blob) => {
        const file = new File([blob], "avatar.jpg", {type: "image/jpeg"})
        const dt = new DataTransfer()
        dt.items.add(file)
        // Re-query at save time — LV may have morphed the live_file_input
        // element after a previous upload (the upload ref refreshes), so
        // a reference cached at mount time can be stale.
        const output = this.el.querySelector("[data-cropper-output]")
        output.files = dt.files
        // LiveView's file-input hook listens for `change`; some configs
        // also respond to `input`. Dispatch both for safety — neither
        // fires automatically when files are assigned programmatically.
        output.dispatchEvent(new Event("input", {bubbles: true}))
        output.dispatchEvent(new Event("change", {bubbles: true}))
        this.reset()
      }, "image/jpeg", 0.92)
    }

    this.input.addEventListener("change", this.onPick)
    this.cancelBtn.addEventListener("click", this.onCancel)
    this.saveBtn.addEventListener("click", this.onSave)
  },
  reset() {
    if (this.cropper) {
      this.cropper.destroy()
      this.cropper = null
    }
    this.stage.hidden = true
    this.input.value = ""
    if (this.image.src) URL.revokeObjectURL(this.image.src)
    this.image.src = ""
  },
  destroyed() {
    if (this.cropper) this.cropper.destroy()
    this.input?.removeEventListener("change", this.onPick)
    this.cancelBtn?.removeEventListener("click", this.onCancel)
    this.saveBtn?.removeEventListener("click", this.onSave)
  }
}

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

