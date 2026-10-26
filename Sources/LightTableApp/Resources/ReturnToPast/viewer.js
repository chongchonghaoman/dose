(function(playcanvas) {
	//#region \0rolldown/runtime.js
	var __create = Object.create;
	var __defProp = Object.defineProperty;
	var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
	var __getOwnPropNames = Object.getOwnPropertyNames;
	var __getProtoOf = Object.getPrototypeOf;
	var __hasOwnProp = Object.prototype.hasOwnProperty;
	var __copyProps = (to, from, except, desc) => {
		if (from && typeof from === "object" || typeof from === "function") for (var keys = __getOwnPropNames(from), i = 0, n = keys.length, key; i < n; i++) {
			key = keys[i];
			if (!__hasOwnProp.call(to, key) && key !== except) __defProp(to, key, {
				get: ((k) => from[k]).bind(null, key),
				enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable
			});
		}
		return to;
	};
	var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", {
		value: mod,
		enumerable: true
	}) : target, mod));
	//#endregion
	playcanvas = __toESM(playcanvas);
	//#region .work/return-to-past-v0.1.85/viewer-build/viewer-scheduler.ts
	var schedulers = /* @__PURE__ */ new WeakMap();
	var FRAME_MS = 1e3 / 60;
	/** Also works before the scene effect installs its scheduler. */
	function requestPreviewRender(app) {
		const scheduler = schedulers.get(app);
		if (scheduler) scheduler.request();
		else app.renderNextFrame = true;
	}
	/** Keeps the engine's update/input loop, but submits GPU work only when dirty.
	* Explicit generations retain requests made inside postrender (AppBase clears
	* renderNextFrame after that event). No model data or React state lives here.
	*/
	var PreviewRenderScheduler = class {
		app;
		dirty = true;
		revision = 0;
		renderingRevision = -1;
		nextFrameAt = -Infinity;
		animationAt = performance.now();
		animating = false;
		forced = 0;
		timer;
		disposed = false;
		handles;
		previousAutoRender;
		constructor(app) {
			this.app = app;
			this.previousAutoRender = app.autoRender;
			app.autoRender = false;
			schedulers.set(app, this);
			this.handles = [
				app.on("framerender", this.beforeFrame),
				app.on("postrender", this.afterFrame),
				app.on("destroy", () => this.destroy())
			];
			document.addEventListener("visibilitychange", this.visibilityChanged);
			this.request();
		}
		get visible() {
			return !document.hidden;
		}
		request() {
			if (this.disposed) return;
			this.dirty = true;
			this.revision++;
			this.app.renderNextFrame = true;
		}
		setAnimating(value) {
			if (this.disposed || this.animating === value) return;
			this.animating = value;
			this.animationAt = performance.now();
			this.request();
		}
		animationDelta() {
			const now = performance.now();
			const delta = this.visible && this.animating ? Math.max(0, now - this.animationAt) / 1e3 : 0;
			this.animationAt = now;
			return delta;
		}
		/** Scoped initialization/capture, never a permanent busy-render fallback. */
		forceFrames = () => {
			if (this.disposed) return () => {};
			this.forced++;
			this.request();
			this.scheduleHiddenFrame();
			let released = false;
			return () => {
				if (released) return;
				released = true;
				this.forced--;
				if (!this.forced && this.timer !== void 0) {
					clearTimeout(this.timer);
					this.timer = void 0;
				}
			};
		};
		beforeFrame = () => {
			if (this.disposed) return;
			this.dirty ||= this.app.renderNextFrame;
			const now = performance.now();
			const wanted = this.dirty || this.animating && this.visible;
			const allowed = this.forced > 0 || this.visible && wanted && now >= this.nextFrameAt - .25;
			this.app.renderNextFrame = allowed;
			if (allowed) {
				this.renderingRevision = this.revision;
				this.nextFrameAt = this.forced || now - this.nextFrameAt > FRAME_MS ? now + FRAME_MS : this.nextFrameAt + FRAME_MS;
			}
		};
		afterFrame = () => {
			if (this.disposed) return;
			if (this.renderingRevision === this.revision) this.dirty = false;
			this.renderingRevision = -1;
		};
		visibilityChanged = () => {
			this.animationAt = performance.now();
			if (this.visible) {
				if (this.timer !== void 0) {
					clearTimeout(this.timer);
					this.timer = void 0;
				}
				this.request();
			} else this.scheduleHiddenFrame();
		};
		scheduleHiddenFrame() {
			if (this.disposed || !this.forced || this.visible || this.timer !== void 0) return;
			this.timer = setTimeout(() => {
				this.timer = void 0;
				if (this.disposed || !this.forced || this.visible) return;
				if (!this.app.graphicsDevice.contextLost) {
					this.renderingRevision = this.revision;
					this.nextFrameAt = performance.now() + FRAME_MS;
					this.app.render();
				}
				this.scheduleHiddenFrame();
			}, FRAME_MS);
		}
		destroy() {
			if (this.disposed) return;
			this.disposed = true;
			if (this.timer !== void 0) clearTimeout(this.timer);
			this.handles.forEach((handle) => handle.off());
			document.removeEventListener("visibilitychange", this.visibilityChanged);
			if (schedulers.get(this.app) === this) {
				schedulers.delete(this.app);
				this.app.autoRender = this.previousAutoRender;
			}
		}
	};
	//#endregion
	//#region .work/return-to-past-v0.1.85/viewer-build/viewer-sort.ts
	var cancelled = () => new DOMException("Preview sorting cancelled", "AbortError");
	/** Application-local compatibility bridge for PlayCanvas 2.21.4's CPU sorter.
	* A busy sorter can silently drop a camera request, while its manager still advances
	* the last-camera cache. Keep that request, and acknowledge only applied results.
	* No Gaussian data or order buffers are copied by this bridge.
	*/
	var PreviewSortCoordinator = class {
		app;
		forceFrames;
		sequence = 0;
		disposed = false;
		trackers = /* @__PURE__ */ new Set();
		managers = /* @__PURE__ */ new WeakSet();
		cameraData = /* @__PURE__ */ new WeakSet();
		restorers = [];
		waits = /* @__PURE__ */ new Set();
		constructor(app, forceFrames = () => () => {}) {
			this.app = app;
			this.forceFrames = forceFrames;
			const director = app.renderer.gsplatDirector;
			if (!director) throw new Error("The Gaussian sorting system is unavailable");
			const original = director.getCameraData;
			director.getCameraData = (...args) => {
				const data = original.apply(director, args);
				this.attachCamera(data);
				return data;
			};
			this.restorers.push(() => {
				director.getCameraData = original;
			});
			for (const data of director.camerasMap.values()) this.attachCamera(data);
			const destroyed = app.on("destroy", () => this.destroy());
			this.restorers.push(() => destroyed.off());
		}
		attachCamera(data) {
			if (this.cameraData.has(data)) return;
			this.cameraData.add(data);
			const original = data.getLayerData;
			data.getLayerData = (...args) => {
				const layer = original.apply(data, args);
				this.attachLayer(layer);
				return layer;
			};
			this.restorers.push(() => {
				data.getLayerData = original;
			});
			for (const layer of data.layersMap.values()) this.attachLayer(layer);
		}
		attachLayer(layer) {
			for (const manager of [layer.gsplatManager, layer.gsplatManagerShadow]) {
				if (!manager || this.managers.has(manager)) continue;
				this.managers.add(manager);
				const original = manager.createSorter;
				manager.createSorter = () => {
					const sorter = original.call(manager);
					this.attachSorter(manager, sorter);
					return sorter;
				};
				this.restorers.push(() => {
					manager.createSorter = original;
				});
				if (manager.cpuSorter) this.attachSorter(manager, manager.cpuSorter);
			}
		}
		view(manager) {
			const camera = manager.cameraNode.camera;
			const state = manager.world.getState(manager.world.lastWorldStateVersion);
			return [
				...manager.cameraNode.getWorldTransform().data,
				...camera.projectionMatrix.data,
				...state?.splats.flatMap((splat) => Array.from(splat.node.getWorldTransform().data)) ?? [],
				Number(this.app.scene.gsplat.radialSorting)
			].join(",");
		}
		attachSorter(manager, sorter) {
			const tracking = {
				manager,
				sorter,
				desired: null,
				applied: null,
				received: null,
				pending: null,
				sent: Array(sorter.jobsInFlight).fill(null),
				disposed: false
			};
			this.trackers.add(tracking);
			const setParams = sorter.setSortParams;
			const setVersion = sorter.setSortParameters;
			const destroy = sorter.destroy;
			const send = (request) => {
				const before = sorter.jobsInFlight;
				setParams.call(sorter, request.params, request.radial);
				if (sorter.jobsInFlight > before) {
					tracking.sent.push(request);
					tracking.pending = null;
				} else tracking.pending = request;
			};
			sorter.setSortParams = (params, radial) => {
				if (this.disposed || tracking.disposed) return;
				const request = {
					sequence: ++this.sequence,
					version: manager.world.lastWorldStateVersion,
					view: this.view(manager),
					params,
					radial
				};
				tracking.desired = request;
				send(request);
			};
			sorter.setSortParameters = (payload) => {
				tracking.pending = null;
				setVersion.call(sorter, payload);
			};
			const message = () => {
				if (this.disposed || tracking.disposed) return;
				tracking.received = tracking.sent.shift() ?? null;
				const pending = tracking.pending;
				if (pending && sorter.jobsInFlight === 0) if (pending.version === manager.world.lastWorldStateVersion && pending.view === this.view(manager)) send(pending);
				else {
					tracking.pending = null;
					manager.sortNeeded = true;
				}
				requestPreviewRender(this.app);
			};
			sorter.worker.addEventListener("message", message);
			const applied = sorter.on("sorted", () => {
				tracking.applied = tracking.received;
			});
			const release = () => {
				if (tracking.disposed) return;
				tracking.disposed = true;
				tracking.pending = null;
				tracking.sent.length = 0;
				sorter.worker?.removeEventListener("message", message);
				applied.off();
				this.trackers.delete(tracking);
				sorter.setSortParams = setParams;
				sorter.setSortParameters = setVersion;
				sorter.destroy = destroy;
			};
			sorter.destroy = () => {
				release();
				destroy.call(sorter);
			};
			this.restorers.push(release);
		}
		waitForFrame(camera, signal, timeoutMessage, timeoutMs = 8e3) {
			if (this.disposed || signal.aborted) return Promise.reject(cancelled());
			const floor = this.sequence;
			const releaseFrames = this.forceFrames();
			const request = () => {
				for (const tracking of this.trackers) if (tracking.manager.cameraNode === camera.entity) tracking.manager.sortNeeded = true;
				requestPreviewRender(this.app);
			};
			request();
			return new Promise((resolve, reject) => {
				let settled = false;
				const finish = (error) => {
					if (settled) return;
					settled = true;
					clearTimeout(timer);
					signal.removeEventListener("abort", abort);
					rendered.off();
					this.waits.delete(fail);
					releaseFrames();
					if (error) reject(error);
					else resolve();
				};
				const fail = (error) => finish(error);
				const abort = () => finish(cancelled());
				const rendered = this.app.on("postrender", () => {
					const active = [...this.trackers].filter((t) => t.manager.cameraNode === camera.entity && t.manager.cpuSorter === t.sorter);
					if (active.length > 0 && active.every((t) => {
						const { world } = t.manager;
						return t.applied && t.desired && t.applied.sequence > floor && t.applied.sequence === t.desired.sequence && !t.pending && t.applied.view === this.view(t.manager) && t.applied.version === world.currentVersion && world.currentVersion === world.lastWorldStateVersion && !world.awaitingLodUpdate && world.pendingLoadCount === 0;
					})) finish();
					else {
						for (const t of active) if (!t.desired || t.desired.sequence <= floor || t.desired.view !== this.view(t.manager) || t.desired.version !== t.manager.world.lastWorldStateVersion) t.manager.sortNeeded = true;
						requestPreviewRender(this.app);
					}
				});
				const timer = setTimeout(() => finish(new Error(timeoutMessage)), timeoutMs);
				signal.addEventListener("abort", abort, { once: true });
				this.waits.add(fail);
			});
		}
		destroy() {
			if (this.disposed) return;
			this.disposed = true;
			for (const fail of [...this.waits]) fail(cancelled());
			for (const restore of this.restorers.reverse()) restore();
			this.restorers.length = 0;
		}
	};
	//#endregion
	//#region .work/return-to-past-v0.1.85/viewer-build/viewer-controls.ts
	var DEFAULT_YAW = 35;
	var DEFAULT_PITCH = 22;
	var DEFAULT_OCCUPANCY = .85;
	var VIEW_TRANSITION_MS = 320;
	var ROLL_LEVEL_MS = 180;
	var MAX_ORBIT_PITCH = 89.9;
	var ORBIT_POLE_EPSILON = 1e-6;
	var ROAM_VISIBLE_HEIGHT_PER_SECOND = .15;
	var ViewerControls = class ViewerControls {
		onOrthographicViewChange;
		onViewChange;
		onMotion;
		static DRAG_THRESHOLD = 3;
		canvas;
		cameraEntity;
		camera;
		target = new playcanvas.Vec3();
		yaw = DEFAULT_YAW;
		pitch = DEFAULT_PITCH;
		distance = 5;
		roll = 0;
		projectionOffset = [0, 0];
		projectionScaleX = 1;
		roamingEnabled = false;
		keys = /* @__PURE__ */ new Set();
		roamFrame = 0;
		roamLastAt = 0;
		roamMoved = false;
		shifted = false;
		previousTabIndex;
		sceneBounds = null;
		horizontalFrameOffset = 0;
		pointerId = null;
		mode = null;
		startX = 0;
		startY = 0;
		lastX = 0;
		lastY = 0;
		dragging = false;
		destroyed = false;
		_enabled = true;
		orbitButton = 0;
		orthographicView = null;
		transitionFrame = 0;
		transitioning = false;
		locating = false;
		leveling = false;
		photoView = null;
		constructor(canvas, cameraEntity, onOrthographicViewChange, cameraError = "The preview camera component is unavailable", onViewChange, onMotion) {
			this.onOrthographicViewChange = onOrthographicViewChange;
			this.onViewChange = onViewChange;
			this.onMotion = onMotion;
			if (!cameraEntity.camera) throw new Error(cameraError);
			this.canvas = canvas;
			this.cameraEntity = cameraEntity;
			this.camera = cameraEntity.camera;
			this.previousTabIndex = canvas.tabIndex;
			canvas.tabIndex = 0;
			canvas.addEventListener("pointerdown", this.focusCanvas, true);
			canvas.addEventListener("blur", this.stopRoaming);
			canvas.addEventListener("pointercancel", this.stopRoaming);
			window.addEventListener("keydown", this.onKeyDown);
			window.addEventListener("keyup", this.onKeyUp);
			window.addEventListener("blur", this.stopRoaming);
			document.addEventListener("visibilitychange", this.stopRoaming);
			canvas.addEventListener("pointerdown", this.onPointerDown);
			canvas.addEventListener("pointermove", this.onPointerMove);
			canvas.addEventListener("pointerup", this.onPointerUp);
			canvas.addEventListener("pointercancel", this.onPointerUp);
			canvas.addEventListener("wheel", this.onWheel, { passive: false });
			canvas.addEventListener("contextmenu", this.preventContextMenu);
			this.updateCamera();
		}
		destroy() {
			if (this.destroyed) return;
			this.destroyed = true;
			this.stopRoaming();
			this.cancelViewTransition();
			this.cancelGesture();
			this.canvas.removeEventListener("pointerdown", this.onPointerDown);
			this.canvas.removeEventListener("pointermove", this.onPointerMove);
			this.canvas.removeEventListener("pointerup", this.onPointerUp);
			this.canvas.removeEventListener("pointercancel", this.onPointerUp);
			this.canvas.removeEventListener("wheel", this.onWheel);
			this.canvas.removeEventListener("contextmenu", this.preventContextMenu);
			this.canvas.removeEventListener("pointerdown", this.focusCanvas, true);
			this.canvas.removeEventListener("blur", this.stopRoaming);
			this.canvas.removeEventListener("pointercancel", this.stopRoaming);
			window.removeEventListener("keydown", this.onKeyDown);
			window.removeEventListener("keyup", this.onKeyUp);
			window.removeEventListener("blur", this.stopRoaming);
			document.removeEventListener("visibilitychange", this.stopRoaming);
			this.canvas.tabIndex = this.previousTabIndex;
			this.camera.calculateProjection = null;
		}
		get enabled() {
			return this._enabled;
		}
		set enabled(value) {
			this._enabled = value;
			if (!value) {
				this.cancelGesture();
				this.stopRoaming();
				if (this.locating || this.leveling) this.stopNavigation();
			}
		}
		setRoamingEnabled(value) {
			this.roamingEnabled = value;
			if (!value) {
				this.stopRoaming();
				if (this.locating || this.leveling) this.stopNavigation();
			}
		}
		get cameraDistance() {
			return this.distance;
		}
		get cameraPitch() {
			return this.pitch;
		}
		/** Single-photo scenes support gentle nearby observation, not a full orbit.
		* Keep zoom independent: this never constrains camera distance.
		*/
		limitToPhotoView() {
			const { right, up } = this.cameraBasis();
			const height = 2 * this.distance * Math.tan(this.camera.fov * Math.PI / 360);
			const aspect = this.canvas.clientWidth / Math.max(this.canvas.clientHeight, 1);
			this.photoView = {
				yaw: this.yaw,
				pitch: this.pitch,
				target: this.target.clone(),
				right,
				up,
				height,
				width: height * Math.max(aspect, .01)
			};
		}
		/** Outward motion eases continuously with remaining room. Inward motion is
		* immediate, with no hidden overscroll to unwind after reaching an edge.
		*/
		photoStep(current, delta, origin, limit) {
			let offset = Math.max(-limit, Math.min(limit, current - origin));
			if (!Number.isFinite(delta) || delta === 0) return origin + offset;
			if (offset * delta < 0) {
				if (Math.abs(delta) <= Math.abs(offset)) return origin + offset + delta;
				delta += offset;
				offset = 0;
			}
			return origin + Math.sign(delta) * (limit - (limit - Math.abs(offset)) * Math.exp(-Math.abs(delta) / limit));
		}
		snapshot() {
			return {
				target: [
					this.target.x,
					this.target.y,
					this.target.z
				],
				yaw: this.yaw,
				pitch: this.pitch,
				distance: this.distance,
				horizontalFrameOffset: this.horizontalFrameOffset,
				projection: this.camera.projection,
				orthoHeight: this.camera.orthoHeight,
				orthographicView: this.orthographicView,
				roll: this.roll,
				fov: this.camera.fov,
				projectionOffset: [...this.projectionOffset],
				projectionScaleX: this.projectionScaleX
			};
		}
		orbitGuideState() {
			const pitch = this.pitch * Math.PI / 180;
			const aspect = this.canvas.clientWidth / Math.max(this.canvas.clientHeight, 1) || Math.max(this.camera.aspectRatio || 16 / 9, .01);
			const horizontalDistance = this.distance * Math.cos(pitch);
			const horizontalFrameShift = this.distance * Math.tan(this.camera.fov * Math.PI / 360) * aspect * this.horizontalFrameOffset;
			return {
				target: [
					this.target.x,
					this.target.y,
					this.target.z
				],
				radius: Math.max(Math.hypot(horizontalDistance, horizontalFrameShift), 1e-4),
				height: this.target.y + this.distance * Math.sin(pitch),
				angleDegrees: this.yaw + Math.atan2(horizontalFrameShift, horizontalDistance) * 180 / Math.PI
			};
		}
		restore(state) {
			this.stopRoaming();
			this.cancelViewTransition();
			this.target.set(...state.target);
			this.yaw = state.yaw;
			this.pitch = state.pitch;
			this.distance = state.distance;
			this.roll = state.roll ?? 0;
			this.camera.fov = state.fov ?? 52;
			this.projectionOffset = [...state.projectionOffset ?? [0, 0]];
			this.projectionScaleX = state.projectionScaleX ?? 1;
			this.horizontalFrameOffset = state.horizontalFrameOffset;
			this.camera.projection = state.projection;
			this.camera.orthoHeight = state.orthoHeight;
			this.orthographicView = state.orthographicView;
			this.onOrthographicViewChange?.(state.orthographicView, state.projection === playcanvas.PROJECTION_ORTHOGRAPHIC);
			this.updateCamera();
		}
		locate(reference, bounds, animate = true) {
			if (this.destroyed || !this.enabled) return;
			this.stopRoaming();
			this.cancelGesture();
			const startPosition = this.cameraEntity.getPosition().clone();
			const startRotation = this.cameraEntity.getRotation().clone();
			const startFov = this.camera.fov;
			const startHeight = this.camera.orthoHeight;
			const startDistance = this.distance;
			const depth = bounds.center.clone().sub(reference.position).dot(reference.forward);
			const distance = depth > 1e-4 ? depth : Math.max(bounds.halfExtents.length(), .01);
			const destination = this.snapshot();
			destination.horizontalFrameOffset = 0;
			const forward = reference.forward.clone().normalize();
			destination.target = reference.position.clone().add(forward.clone().mulScalar(distance)).toArray();
			destination.distance = distance;
			destination.yaw = Math.hypot(forward.x, forward.z) < ORBIT_POLE_EPSILON ? 0 : Math.atan2(-forward.x, -forward.z) * 180 / Math.PI;
			destination.pitch = Math.asin(Math.max(-1, Math.min(1, -forward.y))) * 180 / Math.PI;
			const yaw = destination.yaw * Math.PI / 180;
			const right = new playcanvas.Vec3(Math.cos(yaw), 0, -Math.sin(yaw));
			const up = new playcanvas.Vec3().cross(right, forward).normalize();
			destination.roll = Math.atan2(reference.up.dot(right), reference.up.dot(up)) * 180 / Math.PI;
			destination.projection = playcanvas.PROJECTION_PERSPECTIVE;
			destination.orthographicView = null;
			destination.fov = reference.fov;
			destination.projectionOffset = [...reference.projectionOffset];
			destination.projectionScaleX = reference.projectionScaleX;
			this.restore(destination);
			this.focusCanvas();
			if (!animate || this.destroyed) {
				this.onViewChange?.();
				return;
			}
			const endPosition = this.cameraEntity.getPosition().clone();
			const endRotation = this.cameraEntity.getRotation().clone();
			const endHeight = this.camera.orthoHeight;
			const endFov = this.camera.fov;
			const started = performance.now();
			this.transitioning = true;
			this.locating = true;
			const tick = (now) => {
				if (this.destroyed || !this.transitioning) return;
				if (!this.enabled) {
					this.cancelViewTransition();
					this.updateCamera();
					this.onViewChange?.();
					return;
				}
				const linear = Math.max(0, Math.min(1, (now - started) / VIEW_TRANSITION_MS));
				const t = 1 - (1 - linear) ** 3;
				const position = new playcanvas.Vec3().lerp(startPosition, endPosition, t);
				const rotation = new playcanvas.Quat().slerp(startRotation, endRotation, t);
				const forward = rotation.transformVector(new playcanvas.Vec3(0, 0, -1));
				const up = rotation.transformVector(playcanvas.Vec3.UP);
				this.camera.fov = startFov + (endFov - startFov) * t;
				this.camera.orthoHeight = startHeight + (endHeight - startHeight) * t;
				this.distance = startDistance + (distance - startDistance) * t;
				this.applyCamera(position, position.clone().add(forward), up);
				this.onMotion?.();
				if (linear < 1) this.transitionFrame = requestAnimationFrame(tick);
				else {
					this.transitioning = false;
					this.locating = false;
					this.transitionFrame = 0;
					this.updateCamera();
					this.onViewChange?.();
				}
			};
			this.transitionFrame = requestAnimationFrame(tick);
		}
		orbitBy(degrees) {
			if (!Number.isFinite(degrees) || degrees === 0) return;
			this.cancelViewTransition();
			this.yaw += degrees;
			this.updateCamera();
		}
		setOrbitYaw(yaw) {
			if (!Number.isFinite(yaw)) return;
			this.cancelViewTransition();
			this.yaw = yaw;
			this.updateCamera();
		}
		setSceneBounds(bounds) {
			this.sceneBounds = bounds.clone();
			if (!this.enabled && this.transitioning) {
				this.updateClipPlanes(this.cameraEntity.getPosition(), this.cameraEntity.forward);
				return;
			}
			this.cancelViewTransition();
			this.updateCamera();
		}
		setRectangleSelectionMode(enabled) {
			this.stopNavigation();
			this.orbitButton = enabled ? 1 : 0;
			this.cancelGesture();
		}
		alignOrthographic(view, bounds, occupancy = .85, animate = true) {
			this.stopRoaming();
			this.cancelViewTransition();
			this.cancelGesture();
			const startPosition = this.cameraEntity.getPosition().clone();
			const startTarget = this.target.clone();
			const startUp = this.cameraEntity.up.clone();
			const startOrthoHeight = this.camera.projection === playcanvas.PROJECTION_ORTHOGRAPHIC ? this.camera.orthoHeight : Math.max(this.distance * Math.tan(this.camera.fov * Math.PI / 360), .001);
			this.orthographicView = view;
			this.onOrthographicViewChange?.(view, true);
			this.camera.projection = playcanvas.PROJECTION_ORTHOGRAPHIC;
			const destinationTarget = bounds.center.clone();
			const aspect = this.canvas.clientWidth / Math.max(this.canvas.clientHeight, 1) || 1;
			const half = bounds.halfExtents;
			const [horizontal, vertical] = view === "side" ? [half.z, half.y] : view === "front" ? [half.x, half.y] : [half.x, half.z];
			const destinationOrthoHeight = Math.max(vertical / occupancy, horizontal / Math.max(aspect * occupancy, .001), .001);
			const destinationDistance = Math.max(half.x, half.y, half.z, .01) * 3;
			const destinationPosition = destinationTarget.clone();
			if (view === "side") destinationPosition.x += destinationDistance;
			else if (view === "front") destinationPosition.z += destinationDistance;
			else destinationPosition.y += destinationDistance;
			const destinationUp = view === "top" ? new playcanvas.Vec3(0, 0, -1) : playcanvas.Vec3.UP.clone();
			this.target.copy(destinationTarget);
			this.camera.orthoHeight = destinationOrthoHeight;
			this.distance = destinationDistance;
			this.horizontalFrameOffset = 0;
			this.roll = 0;
			this.projectionOffset = [0, 0];
			this.projectionScaleX = 1;
			this.onViewChange?.();
			if (!animate || this.destroyed) {
				this.updateCamera();
				return;
			}
			this.transitioning = true;
			let startedAt = performance.now();
			let previousFrameAt = startedAt;
			const position = new playcanvas.Vec3();
			const lookTarget = new playcanvas.Vec3();
			const up = new playcanvas.Vec3();
			const tick = (now) => {
				if (this.destroyed || !this.transitioning) return;
				if (!this.enabled) {
					startedAt += now - previousFrameAt;
					previousFrameAt = now;
					this.transitionFrame = requestAnimationFrame(tick);
					return;
				}
				previousFrameAt = now;
				const linear = Math.min(1, Math.max(0, (now - startedAt) / VIEW_TRANSITION_MS));
				const progress = 1 - Math.pow(1 - linear, 3);
				position.lerp(startPosition, destinationPosition, progress);
				lookTarget.lerp(startTarget, destinationTarget, progress);
				up.lerp(startUp, destinationUp, progress).normalize();
				this.camera.orthoHeight = startOrthoHeight + (destinationOrthoHeight - startOrthoHeight) * progress;
				this.applyCamera(position, lookTarget, up);
				if (linear < 1) this.transitionFrame = requestAnimationFrame(tick);
				else {
					this.transitioning = false;
					this.transitionFrame = 0;
					this.updateCamera();
					this.onViewChange?.();
				}
			};
			this.transitionFrame = requestAnimationFrame(tick);
		}
		usePerspective() {
			this.cancelViewTransition();
			this.orthographicView = null;
			this.onOrthographicViewChange?.(null, false);
			this.camera.projection = playcanvas.PROJECTION_PERSPECTIVE;
			this.updateCamera();
		}
		cancelGesture() {
			this.pointerId = null;
			this.mode = null;
			this.dragging = false;
		}
		fit(bounds, options = {}) {
			this.cancelViewTransition();
			if (options.resetDirection) {
				this.yaw = DEFAULT_YAW;
				this.pitch = DEFAULT_PITCH;
				this.roll = 0;
			}
			const occupancy = Math.max(.5, Math.min(.98, options.occupancy ?? DEFAULT_OCCUPANCY));
			if (this.camera.projection === playcanvas.PROJECTION_ORTHOGRAPHIC && this.orthographicView) {
				this.alignOrthographic(this.orthographicView, bounds, occupancy, false);
				return;
			}
			const width = Math.max(this.canvas.clientWidth, 1);
			const height = Math.max(this.canvas.clientHeight, 1);
			const aspect = width > 1 && height > 1 ? width / height : Math.max(this.camera.aspectRatio || 16 / 9, .01);
			const rightInset = width > 1 ? Math.max(0, Math.min(options.rightInsetPx ?? 0, width * .45)) : 0;
			const usableWidthRatio = Math.max(.55, (width - rightInset) / width);
			const halfVerticalFov = this.camera.fov * Math.PI / 360;
			const verticalCapacity = Math.max(Math.tan(halfVerticalFov) * occupancy, .001);
			const horizontalCapacity = Math.max(verticalCapacity * aspect * usableWidthRatio, .001);
			const { forward, right, up } = this.cameraBasis();
			const center = bounds.center;
			const half = bounds.halfExtents;
			let requiredDistance = .05;
			for (const x of [-half.x, half.x]) for (const y of [-half.y, half.y]) for (const z of [-half.z, half.z]) {
				const corner = new playcanvas.Vec3(x, y, z);
				const horizontal = Math.abs(corner.dot(right));
				const vertical = Math.abs(corner.dot(up));
				const depth = corner.dot(forward);
				requiredDistance = Math.max(requiredDistance, horizontal / horizontalCapacity - depth, vertical / verticalCapacity - depth, -depth + .01);
			}
			this.target.copy(center);
			this.distance = Math.max(requiredDistance, .05);
			this.horizontalFrameOffset = width > 1 ? rightInset / width : 0;
			this.updateCamera();
		}
		cameraBasis() {
			const yaw = this.yaw * Math.PI / 180;
			const pitch = this.pitch * Math.PI / 180;
			const offset = new playcanvas.Vec3(Math.sin(yaw) * Math.cos(pitch), Math.sin(pitch), Math.cos(yaw) * Math.cos(pitch));
			const forward = offset.clone().mulScalar(-1);
			const baseRight = new playcanvas.Vec3(Math.cos(yaw), 0, -Math.sin(yaw));
			const baseUp = new playcanvas.Vec3().cross(baseRight, forward).normalize();
			const roll = this.roll * Math.PI / 180;
			return {
				offset,
				forward,
				right: baseRight.clone().mulScalar(Math.cos(roll)).sub(baseUp.clone().mulScalar(Math.sin(roll))),
				up: baseUp.mulScalar(Math.cos(roll)).add(baseRight.mulScalar(Math.sin(roll)))
			};
		}
		updateCamera() {
			if (this.orthographicView) {
				const position = this.target.clone();
				if (this.orthographicView === "side") position.x += this.distance;
				else if (this.orthographicView === "front") position.z += this.distance;
				else position.y += this.distance;
				this.applyCamera(position, this.target, this.orthographicView === "top" ? new playcanvas.Vec3(0, 0, -1) : playcanvas.Vec3.UP);
				return;
			}
			const { offset, right, up } = this.cameraBasis();
			const canvasAspect = this.canvas.clientWidth / Math.max(this.canvas.clientHeight, 1);
			const aspect = canvasAspect > 0 ? canvasAspect : Math.max(this.camera.aspectRatio || 16 / 9, .01);
			const halfVerticalFov = this.camera.fov * Math.PI / 360;
			const viewTarget = this.target.clone().add(right.mulScalar(this.distance * Math.tan(halfVerticalFov) * aspect * this.horizontalFrameOffset));
			const position = viewTarget.clone().add(offset.mulScalar(this.distance));
			this.applyCamera(position, viewTarget, up);
		}
		applyCamera(position, lookTarget, up) {
			const forward = lookTarget.clone().sub(position).normalize();
			const bounds = this.sceneBounds;
			if (this.camera.projection === playcanvas.PROJECTION_ORTHOGRAPHIC && bounds) {
				const half = bounds.halfExtents;
				const radius = Math.abs(forward.x) * half.x + Math.abs(forward.y) * half.y + Math.abs(forward.z) * half.z;
				const minimumDepth = bounds.center.clone().sub(position).dot(forward) - radius;
				const margin = Math.max(half.length() * .01, .001);
				if (minimumDepth < margin) position.sub(forward.clone().mulScalar(margin - minimumDepth));
			}
			this.cameraEntity.setPosition(position);
			this.cameraEntity.lookAt(lookTarget, up);
			this.updateClipPlanes(position, forward);
			this.camera.calculateProjection = this.projectionOffset.some((value) => value !== 0) || this.projectionScaleX !== 1 ? this.calculateProjection : null;
			this.onMotion?.();
		}
		calculateProjection = (matrix) => {
			const aspect = Math.max(this.camera.aspectRatio || 1, 1e-4);
			if (this.camera.projection === playcanvas.PROJECTION_ORTHOGRAPHIC) {
				const h = this.camera.orthoHeight;
				matrix.setOrtho(-h * aspect, h * aspect, -h, h, this.camera.nearClip, this.camera.farClip);
				matrix.data[0] *= this.projectionScaleX;
			} else {
				matrix.setPerspective(this.camera.fov, aspect, this.camera.nearClip, this.camera.farClip);
				matrix.data[0] *= this.projectionScaleX;
				matrix.data[8] = -2 * this.projectionOffset[0] / aspect;
				matrix.data[9] = 2 * this.projectionOffset[1];
			}
		};
		visibleHeight() {
			return this.camera.projection === playcanvas.PROJECTION_ORTHOGRAPHIC ? this.camera.orthoHeight * 2 : 2 * this.distance * Math.tan(this.camera.fov * Math.PI / 360);
		}
		focusCanvas = () => {
			if (this.enabled) this.canvas.focus({ preventScroll: true });
		};
		stopRoaming = () => {
			if (this.roamFrame) cancelAnimationFrame(this.roamFrame);
			this.roamFrame = 0;
			this.keys.clear();
			if (this.roamMoved) {
				this.roamMoved = false;
				this.onViewChange?.();
			}
		};
		onKeyDown = (event) => {
			if (event.ctrlKey || event.metaKey || event.altKey) {
				this.stopRoaming();
				return;
			}
			if (this.destroyed || !this.enabled || !this.roamingEnabled || this.camera.projection !== playcanvas.PROJECTION_PERSPECTIVE || document.activeElement !== this.canvas || event.target !== this.canvas || this.pointerId !== null) return;
			this.shifted = event.shiftKey;
			if (![
				"KeyW",
				"KeyA",
				"KeyS",
				"KeyD"
			].includes(event.code)) return;
			if (event.repeat && !this.keys.has(event.code)) return;
			event.preventDefault();
			this.cancelViewTransition(true);
			this.keys.add(event.code);
			if (!this.roamFrame) {
				this.roamLastAt = performance.now();
				this.roamFrame = requestAnimationFrame(this.roam);
			}
		};
		onKeyUp = (event) => {
			this.shifted = event.shiftKey;
			this.keys.delete(event.code);
			if (!this.keys.size) this.stopRoaming();
		};
		roam = (now) => {
			this.roamFrame = 0;
			if (this.destroyed || !this.enabled || !this.roamingEnabled || document.activeElement !== this.canvas || this.camera.projection !== playcanvas.PROJECTION_PERSPECTIVE || !this.keys.size) {
				this.stopRoaming();
				return;
			}
			const sampleAt = Math.max(this.roamLastAt, now);
			const dt = Math.min(.05, (sampleAt - this.roamLastAt) / 1e3);
			this.roamLastAt = sampleAt;
			const forward = Number(this.keys.has("KeyW")) - Number(this.keys.has("KeyS"));
			const right = Number(this.keys.has("KeyD")) - Number(this.keys.has("KeyA"));
			const yaw = this.yaw * Math.PI / 180;
			const movement = new playcanvas.Vec3(-Math.sin(yaw) * forward + Math.cos(yaw) * right, 0, -Math.cos(yaw) * forward - Math.sin(yaw) * right);
			if (movement.lengthSq() > 0) {
				movement.normalize().mulScalar(ROAM_VISIBLE_HEIGHT_PER_SECOND * this.visibleHeight() * dt * (this.shifted ? 3 : 1));
				this.target.add(movement);
				const position = this.cameraEntity.getPosition().clone().add(movement);
				this.cameraEntity.setPosition(position);
				this.updateClipPlanes(position, this.cameraEntity.forward);
				this.onMotion?.();
				this.roamMoved = true;
			}
			this.roamFrame = requestAnimationFrame(this.roam);
		};
		updateClipPlanes(cameraPosition, forward) {
			const bounds = this.sceneBounds;
			if (!bounds) {
				this.camera.nearClip = Math.max(this.distance * .001, 1e-4);
				this.camera.farClip = Math.max(this.distance * 10, 100);
				return;
			}
			const center = bounds.center;
			const half = bounds.halfExtents;
			let minimumDepth = Number.POSITIVE_INFINITY;
			let maximumDepth = 0;
			let crossesCameraPlane = false;
			for (const x of [-half.x, half.x]) for (const y of [-half.y, half.y]) for (const z of [-half.z, half.z]) {
				const depth = new playcanvas.Vec3(center.x + x, center.y + y, center.z + z).sub(cameraPosition).dot(forward);
				if (depth <= 0) crossesCameraPlane = true;
				else minimumDepth = Math.min(minimumDepth, depth);
				maximumDepth = Math.max(maximumDepth, depth);
			}
			const near = crossesCameraPlane || !Number.isFinite(minimumDepth) ? 1e-4 : Math.max(minimumDepth * .2, 1e-4);
			this.camera.nearClip = near;
			this.camera.farClip = Math.max(maximumDepth * 1.25, near + 1, 10);
		}
		preventContextMenu = (event) => event.preventDefault();
		cancelViewTransition(preservePose = false) {
			if (preservePose && this.transitioning && !this.leveling) {
				const forward = this.cameraEntity.forward.clone();
				const up = this.cameraEntity.up.clone();
				this.yaw = Math.hypot(forward.x, forward.z) < ORBIT_POLE_EPSILON ? 0 : Math.atan2(-forward.x, -forward.z) * 180 / Math.PI;
				this.pitch = Math.asin(Math.max(-1, Math.min(1, -forward.y))) * 180 / Math.PI;
				const yaw = this.yaw * Math.PI / 180;
				const right = new playcanvas.Vec3(Math.cos(yaw), 0, -Math.sin(yaw));
				const baseUp = new playcanvas.Vec3().cross(right, forward).normalize();
				this.roll = Math.atan2(up.dot(right), up.dot(baseUp)) * 180 / Math.PI;
				this.target.copy(this.cameraEntity.getPosition()).add(forward.mulScalar(this.distance));
				this.horizontalFrameOffset = 0;
				this.orthographicView = null;
				this.onOrthographicViewChange?.(null, this.camera.projection === playcanvas.PROJECTION_ORTHOGRAPHIC);
			}
			if (this.transitionFrame) cancelAnimationFrame(this.transitionFrame);
			this.transitionFrame = 0;
			this.transitioning = false;
			this.locating = false;
			this.leveling = false;
		}
		beginRollLeveling() {
			if (this.leveling) return;
			const startRoll = ((this.roll + 180) % 360 + 360) % 360 - 180;
			if (Math.abs(startRoll) < 1e-6) {
				this.roll = 0;
				return;
			}
			this.cancelViewTransition();
			this.roll = startRoll;
			this.transitioning = true;
			this.leveling = true;
			const started = performance.now();
			const tick = (now) => {
				if (this.destroyed || !this.leveling) return;
				const t = Math.max(0, Math.min(1, (now - started) / ROLL_LEVEL_MS));
				this.roll = t === 1 ? 0 : startRoll * (1 - t) ** 3;
				this.updateCamera();
				if (t < 1) this.transitionFrame = requestAnimationFrame(tick);
				else {
					this.transitionFrame = 0;
					this.transitioning = false;
					this.leveling = false;
					this.onViewChange?.();
				}
			};
			this.transitionFrame = requestAnimationFrame(tick);
		}
		stopNavigation() {
			this.stopRoaming();
			this.cancelGesture();
			if (this.transitioning) {
				this.cancelViewTransition(true);
				this.updateCamera();
				this.onViewChange?.();
			}
		}
		onPointerDown = (event) => {
			this.stopRoaming();
			if (this.destroyed || !this.enabled || event.button !== this.orbitButton && event.button !== 2) return;
			this.cancelViewTransition(true);
			this.pointerId = event.pointerId;
			this.mode = event.button === this.orbitButton ? "orbit" : "pan";
			this.startX = event.clientX;
			this.startY = event.clientY;
			this.lastX = event.clientX;
			this.lastY = event.clientY;
			this.dragging = false;
			this.canvas.setPointerCapture(event.pointerId);
		};
		onPointerMove = (event) => {
			if (this.destroyed || !this.enabled || this.pointerId !== event.pointerId || !this.mode) return;
			if (!this.dragging) {
				if (Math.hypot(event.clientX - this.startX, event.clientY - this.startY) < ViewerControls.DRAG_THRESHOLD) return;
				this.dragging = true;
			}
			const dx = event.clientX - this.lastX;
			const dy = event.clientY - this.lastY;
			this.lastX = event.clientX;
			this.lastY = event.clientY;
			if (this.mode === "orbit") {
				if (this.orthographicView) {
					const direction = this.cameraEntity.getPosition().clone().sub(this.target).normalize();
					const horizontalLength = Math.hypot(direction.x, direction.z);
					this.yaw = horizontalLength < ORBIT_POLE_EPSILON ? 0 : Math.atan2(direction.x, direction.z) * 180 / Math.PI;
					this.pitch = Math.max(-89.9, Math.min(MAX_ORBIT_PITCH, Math.asin(Math.max(-1, Math.min(1, direction.y))) * 180 / Math.PI));
					this.orthographicView = null;
					this.onOrthographicViewChange?.(null, true);
				}
				this.beginRollLeveling();
				if (this.photoView) {
					this.yaw = this.photoStep(this.yaw, -dx * .075, this.photoView.yaw, 8);
					this.pitch = this.photoStep(this.pitch, dy * .075, this.photoView.pitch, 5);
				} else {
					this.yaw -= dx * .3;
					this.pitch = Math.max(-89.9, Math.min(MAX_ORBIT_PITCH, this.pitch + dy * .3));
				}
			} else {
				const speed = this.visibleHeight() / Math.max(this.canvas.clientHeight, 1) * (this.photoView ? .25 : 1);
				const movement = this.cameraEntity.right.clone().mulScalar(-dx * speed / this.projectionScaleX).add(this.cameraEntity.up.clone().mulScalar(dy * speed));
				const photo = this.photoView;
				if (photo) {
					const offset = this.target.clone().sub(photo.target);
					const x = this.photoStep(offset.dot(photo.right), movement.dot(photo.right), 0, photo.width * .06);
					const y = this.photoStep(offset.dot(photo.up), movement.dot(photo.up), 0, photo.height * .06);
					this.target.copy(photo.target).add(photo.right.clone().mulScalar(x)).add(photo.up.clone().mulScalar(y));
				} else this.target.add(movement);
			}
			this.updateCamera();
		};
		onPointerUp = (event) => {
			if (this.pointerId !== event.pointerId) return;
			if (this.canvas.hasPointerCapture(event.pointerId)) this.canvas.releasePointerCapture(event.pointerId);
			this.cancelGesture();
			this.onViewChange?.();
		};
		onWheel = (event) => {
			if (this.destroyed || !this.enabled) return;
			this.cancelViewTransition(true);
			event.preventDefault();
			const modeScale = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? Math.max(this.canvas.clientHeight, 800) : 1;
			const delta = Math.max(-240, Math.min(240, event.deltaY * modeScale));
			const sensitivity = this.photoView ? 5e-4 : .001;
			if (this.camera.projection === playcanvas.PROJECTION_ORTHOGRAPHIC) this.camera.orthoHeight = Math.max(1e-4, Math.min(1e6, this.camera.orthoHeight * Math.exp(delta * sensitivity)));
			else this.distance = Math.max(.01, Math.min(1e6, this.distance * Math.exp(delta * sensitivity)));
			this.updateCamera();
			this.onViewChange?.();
		};
	};
	//#endregion
	//#region .work/return-to-past-v0.1.85/viewer-build/viewer-backend.ts
	var PREVIEW_DEVICE_TYPES = [playcanvas.DEVICETYPE_WEBGPU, playcanvas.DEVICETYPE_WEBGL2];
	function previewDeviceTypes() {
		return [...PREVIEW_DEVICE_TYPES];
	}
	function configurePreviewRenderer(app) {
		app.scene.gsplat.renderer = playcanvas.GSPLAT_RENDERER_RASTER_CPU_SORT;
	}
	//#endregion
	//#region .work/return-to-past-v0.1.85/viewer-build/viewer-entry.ts
	var canvas = document.getElementById("scene");
	var REVEAL_SECONDS = 5;
	var current;
	var interactive = true;
	var revealGLSL = `
uniform float uRevealProgress;
uniform float uReducedMotion;
float revealAge(vec3 center) {
    float seed = fract(sin(dot(center, vec3(127.1, 311.7, 74.7))) * 43758.5453);
    float delay = pow(seed, 0.35) * 0.72;
    return clamp((uRevealProgress - delay) / 0.28, 0.0, 1.0);
}
void modifySplatCenter(inout vec3 center) {}
void modifySplatRotationScale(vec3 originalCenter, vec3 modifiedCenter, inout vec4 rotation, inout vec3 scale) {
    if (uRevealProgress >= 1.0) return;
    float growth = smoothstep(0.0, 1.0, revealAge(originalCenter));
    scale *= mix(mix(0.018, 1.0, growth), 1.0, uReducedMotion);
}
void modifySplatColor(vec3 center, inout vec4 color) {
    if (uRevealProgress >= 1.0) return;
    float alpha = smoothstep(0.0, 0.12, revealAge(center));
    color.a *= mix(alpha, uRevealProgress, uReducedMotion);
}`;
	var revealWGSL = `
uniform uRevealProgress: f32;
uniform uReducedMotion: f32;
fn revealAge(center: vec3f) -> f32 {
    let seed = fract(sin(dot(center, vec3f(127.1, 311.7, 74.7))) * 43758.5453);
    let delay = pow(seed, 0.35) * 0.72;
    return clamp((uniform.uRevealProgress - delay) / 0.28, 0.0, 1.0);
}
fn modifySplatCenter(center: ptr<function, vec3f>) {}
fn modifySplatRotationScale(originalCenter: vec3f, modifiedCenter: vec3f, rotation: ptr<function, vec4f>, scale: ptr<function, vec3f>) {
    if (uniform.uRevealProgress >= 1.0) { return; }
    let growth = smoothstep(0.0, 1.0, revealAge(originalCenter));
    *scale = *scale * mix(mix(0.018, 1.0, growth), 1.0, uniform.uReducedMotion);
}
fn modifySplatColor(center: vec3f, color: ptr<function, vec4f>) {
    if (uniform.uRevealProgress >= 1.0) { return; }
    let alpha = smoothstep(0.0, 0.12, revealAge(center));
    var updated = *color;
    updated.a *= mix(alpha, uniform.uRevealProgress, uniform.uReducedMotion);
    *color = updated;
}`;
	function post(type, message) {
		(window.webkit?.messageHandlers?.returnToPast)?.postMessage(message ? {
			type,
			message
		} : { type });
	}
	function valid(session) {
		return current === session && !session.abort.signal.aborted;
	}
	function updateCursor() {
		canvas.style.cursor = interactive && current?.revealed ? "grab" : "default";
	}
	function release(session) {
		session.abort.abort();
		session.controls?.destroy();
		session.sorting?.destroy();
		session.releases.splice(0).forEach((fn) => fn());
		session.scheduler?.destroy();
		session.entity?.destroy();
		if (session.asset && session.app) {
			session.asset.unload();
			session.app.assets.remove(session.asset);
		}
		session.app?.destroy();
	}
	function dispose() {
		const session = current;
		current = void 0;
		if (session) release(session);
		canvas.style.visibility = "hidden";
		updateCursor();
	}
	function fail(session, error) {
		if (!valid(session)) return;
		const message = error instanceof Error ? error.message : String(error);
		dispose();
		post("error", message || "无法播放这个高斯场景，请重试。");
	}
	function requestFrame(session) {
		session.scheduler?.request();
	}
	function resetView() {
		const session = current;
		if (!session?.revealed || !interactive || !session.startView) return;
		session.controls?.restore(session.startView);
	}
	function magnifyBy(delta) {
		const session = current;
		if (!session?.revealed || !interactive || !Number.isFinite(delta)) return;
		const controls = session.controls;
		const view = controls.snapshot();
		const amount = Math.min(.08, Math.max(-.08, delta)) * .25;
		controls.restore({
			...view,
			distance: Math.max(.01, Math.min(1e6, view.distance * Math.exp(-amount)))
		});
	}
	function setRevealProgress(session, progress) {
		const material = session.app.scene.gsplat.material;
		material.setParameter("uRevealProgress", progress);
		material.dirty = true;
	}
	function configureResolution(session) {
		const app = session.app;
		const device = app.graphicsDevice;
		let ratioQuery;
		const resize = () => {
			if (!valid(session)) return;
			const width = Math.max(1, window.innerWidth);
			const height = Math.max(1, window.innerHeight);
			const renderLimit = device.maxRenderBufferSize || device.maxTextureSize;
			device.maxPixelRatio = Math.min(Math.max(1, window.devicePixelRatio || 1), 1.5, Math.sqrt(2e6 / (width * height)), device.maxTextureSize / width, device.maxTextureSize / height, renderLimit / width, renderLimit / height);
			app.setCanvasResolution(playcanvas.RESOLUTION_AUTO, width, height);
			app.resizeCanvas(width, height);
			requestFrame(session);
		};
		const watch = () => {
			ratioQuery?.removeEventListener("change", changed);
			ratioQuery = window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`);
			ratioQuery.addEventListener("change", changed);
		};
		const changed = () => {
			resize();
			watch();
		};
		app.setCanvasFillMode(playcanvas.FILLMODE_FILL_WINDOW, window.innerWidth, window.innerHeight);
		window.addEventListener("resize", resize);
		resize();
		watch();
		session.releases.push(() => {
			window.removeEventListener("resize", resize);
			ratioQuery?.removeEventListener("change", changed);
		});
	}
	function loadAsset(session, asset) {
		return new Promise((resolve, reject) => {
			const cleanup = () => {
				asset.off("load", loaded);
				asset.off("error", failed);
				session.abort.signal.removeEventListener("abort", aborted);
			};
			const loaded = () => {
				cleanup();
				resolve();
			};
			const failed = (error) => {
				cleanup();
				reject(error);
			};
			const aborted = () => failed(new DOMException("场景已关闭", "AbortError"));
			asset.once("load", loaded);
			asset.once("error", failed);
			session.abort.signal.addEventListener("abort", aborted, { once: true });
			session.app.assets.load(asset);
		});
	}
	function finishReveal(session) {
		if (!valid(session) || session.revealed || session.finishing) return;
		session.finishing = true;
		setRevealProgress(session, 1);
		session.scheduler.setAnimating(false);
		requestFrame(session);
		const rendered = session.app.once("postrender", () => {
			if (!valid(session)) return;
			session.revealed = true;
			session.controls.enabled = interactive;
			updateCursor();
			post("revealed");
		});
		session.releases.push(() => rendered.off());
	}
	async function boot(session, config) {
		const parsed = new URL(config.modelURL);
		if (parsed.protocol !== "lighttable-scene:" || parsed.hostname !== "local") throw new Error("场景资源地址无效。");
		for (const value of [
			config.width,
			config.height,
			config.focal,
			config.depth
		]) if (!Number.isFinite(value) || value <= 0) throw new Error("场景相机参数无效。");
		const device = await playcanvas.createGraphicsDevice(canvas, {
			deviceTypes: previewDeviceTypes(),
			antialias: false,
			powerPreference: "high-performance"
		});
		if (!valid(session)) {
			device.destroy();
			return;
		}
		if (!device.isWebGPU && !device.isWebGL2) {
			device.destroy();
			throw new Error("这台电脑暂时无法创建高斯播放窗口。");
		}
		const app = new playcanvas.Application(canvas, { graphicsDevice: device });
		session.app = app;
		app.scene.gsplatCentersEnabled = true;
		configurePreviewRenderer(app);
		app.scene.gsplat.colorUpdateAngle = 0;
		session.scheduler = new PreviewRenderScheduler(app);
		session.sorting = new PreviewSortCoordinator(app, session.scheduler.forceFrames);
		const lost = device.on("devicelost", () => fail(session, /* @__PURE__ */ new Error("图形设备已中断，请重新打开场景。")));
		session.releases.push(() => lost.off());
		configureResolution(session);
		const camera = new playcanvas.Entity("SHARP initial view");
		camera.addComponent("camera", {
			clearColor: new playcanvas.Color(0, 0, 0),
			fov: 2 * Math.atan(config.height / (2 * config.focal)) * 180 / Math.PI,
			nearClip: .02,
			farClip: 1e3,
			gammaCorrection: playcanvas.GAMMA_SRGB,
			toneMapping: playcanvas.TONEMAP_LINEAR
		});
		app.root.addChild(camera);
		session.camera = camera;
		const controls = new ViewerControls(canvas, camera, void 0, "无法创建场景相机。", void 0, () => requestFrame(session));
		session.controls = controls;
		session.startView = {
			target: [
				0,
				0,
				config.depth
			],
			yaw: 180,
			pitch: 0,
			distance: config.depth,
			horizontalFrameOffset: 0,
			projection: playcanvas.PROJECTION_PERSPECTIVE,
			orthoHeight: 1,
			orthographicView: null,
			fov: camera.camera.fov
		};
		controls.restore(session.startView);
		controls.limitToPhotoView();
		controls.enabled = false;
		const asset = new playcanvas.Asset("Local SHARP scene", "gsplat", {
			url: config.modelURL,
			filename: "scene.ply"
		}, { reorder: false });
		session.asset = asset;
		app.assets.add(asset);
		await loadAsset(session, asset);
		if (!valid(session)) return;
		const resource = asset.resource;
		if (!resource || Math.ceil(Math.sqrt(resource.numSplats)) > device.maxTextureSize) throw new Error("场景超出当前图形设备的纹理容量。");
		const entity = new playcanvas.Entity("SHARP Gaussians");
		entity.setLocalEulerAngles(0, 0, 180);
		app.root.addChild(entity);
		session.entity = entity;
		entity.addComponent("gsplat", {
			asset,
			unified: true
		});
		const component = entity.gsplat;
		const worldBounds = new playcanvas.BoundingBox();
		worldBounds.setFromTransformedAabb(resource.aabb, entity.getWorldTransform());
		controls.setSceneBounds(worldBounds);
		controls.restore(session.startView);
		const material = app.scene.gsplat.material;
		material.shaderChunks.glsl.set("gsplatModifyVS", revealGLSL);
		material.shaderChunks.wgsl.set("gsplatModifyVS", revealWGSL);
		material.setParameter("uReducedMotion", config.reduceMotion ? 1 : 0);
		setRevealProgress(session, 0);
		material.update();
		component.workBufferUpdate = playcanvas.WORKBUFFER_UPDATE_AUTO;
		session.duration = config.reduceMotion ? .25 : REVEAL_SECONDS;
		const update = app.on("update", () => {
			if (!valid(session) || session.revealed || session.finishing || !session.scheduler.visible) return;
			if (session.elapsed < 0) return;
			session.elapsed = Math.min(session.duration, session.elapsed + session.scheduler.animationDelta());
			setRevealProgress(session, Math.max(0, (session.elapsed - (config.reduceMotion ? 0 : .35)) / (session.duration - (config.reduceMotion ? 0 : .35))));
			requestFrame(session);
			if (session.elapsed >= session.duration) finishReveal(session);
		});
		session.releases.push(() => update.off());
		app.start();
		await session.sorting.waitForFrame(camera.camera, session.abort.signal, "场景排序超时，请重新打开重试。", 3e4);
		if (!valid(session)) return;
		canvas.style.visibility = "visible";
		session.elapsed = 0;
		if (config.skipReveal) finishReveal(session);
		else session.scheduler.setAnimating(true);
	}
	function loadScene(config) {
		dispose();
		const session = {
			abort: new AbortController(),
			releases: [],
			revealed: false,
			finishing: false,
			elapsed: -1,
			duration: REVEAL_SECONDS
		};
		current = session;
		boot(session, config).catch((error) => fail(session, error));
	}
	function setInteractive(value) {
		interactive = Boolean(value);
		if (current?.controls) current.controls.enabled = interactive && current.revealed;
		updateCursor();
	}
	canvas.addEventListener("dblclick", (event) => {
		event.preventDefault();
		resetView();
	});
	canvas.addEventListener("webglcontextlost", (event) => {
		event.preventDefault();
		if (current) fail(current, /* @__PURE__ */ new Error("图形设备已中断，请重新打开场景。"));
	});
	window.addEventListener("pagehide", dispose);
	window.addEventListener("error", (event) => {
		if (current) fail(current, event.error || event.message);
	});
	window.addEventListener("unhandledrejection", (event) => {
		if (current) fail(current, event.reason);
	});
	Object.assign(window, {
		loadScene,
		setInteractive,
		resetView,
		magnifyBy,
		dispose,
		setExpanded: () => {
			if (current) window.dispatchEvent(new Event("resize"));
		}
	});
	post("ready");
	//#endregion
})(pc);
