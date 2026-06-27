ChronoForge::Dashboard::Engine.routes.draw do
  root to: "workflows#index"
  resources :workflows, only: %i[index show] do
    member do
      post :retry, to: "actions#retry"
      post :resume, to: "actions#resume"
      post :unlock, to: "actions#unlock"
      get :repetitions, to: "repetitions#index"
    end
    collection do
      post :bulk_retry, to: "actions#bulk_retry"
    end
    resources :branches, only: :show, controller: "branch_children" do
      member { post :bulk_retry, to: "actions#bulk_retry_branch" }
    end
  end
  resources :wait_states, only: :index
  get "analytics", to: "analytics#index", as: :analytics
  get "assets/:file", to: "assets#show", constraints: {file: /dashboard\.(css|js)/}
end
