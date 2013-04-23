class ConsoleIndexController < ConsoleController
  skip_before_filter :authenticate_user!, :only => :unauthorized

  def index
    redirect_to applications_path
  end
  def unauthorized
    render 'console/unauthorized'
  end
  def server_maintenance
    render 'console/server_maintenance'
  end

  def help
    render 'console/help'
  end
end
