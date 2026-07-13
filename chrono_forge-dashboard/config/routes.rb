ChronoForge::Dashboard::Engine.routes.draw do
  root to: "workflows#index"
  resources :workflows, only: %i[index show] do
    member do
      post :retry, to: "actions#retry"
      post :resume, to: "actions#resume"
      post :unlock, to: "actions#unlock"
      post :reap, to: "actions#reap"
      get :repetitions, to: "repetitions#index"
      get :definition, to: "definitions#show"
    end
    collection do
      post :bulk_retry, to: "actions#bulk_retry"
    end
    resources :branches, only: :show, controller: "branch_children" do
      member { post :bulk_retry, to: "actions#bulk_retry_branch" }
    end
  end
  resources :wait_states, only: :index
  resources :stranded, only: :index do
    collection { post :reap_all, to: "actions#bulk_reap" }
  end
  get "overview", to: "overview#index", as: :overview
  # Each Overview section loads in its own turbo-frame (see overview/index) so the
  # shell paints instantly and the heavy per-class scan can't block the cheap card
  # counts. One action per frame.
  scope "overview", as: :overview do
    get "processed", to: "overview#processed"
    get "in_flight", to: "overview#in_flight"
    get "blocked", to: "overview#blocked"
    get "classes", to: "overview#classes"
  end
  get "analytics", to: "analytics#index", as: :analytics
  # Explicit allowlist (mirrors AssetsController::TYPES) so unknown assets 404 at
  # the routing layer rather than reaching the controller.
  get "assets/:file", to: "assets#show", constraints: {
    file: /(dashboard\.(css|js)|turbo\.min\.js|cytoscape\.min\.js|dagre\.min\.js|cytoscape-dagre\.js|definition_graph\.js)/
  }
end
