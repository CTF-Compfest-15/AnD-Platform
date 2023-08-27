from and_platform.models import db, Challenges, Teams, Services, Servers
from and_platform.core.config import get_config
from and_platform.core.service import do_provision, do_patch, do_restart, do_reset, get_service_path
from flask import Blueprint, jsonify, request, views, current_app as app

import os

service_blueprint = Blueprint("service", __name__, url_prefix="/services")

class ServiceProvision(views.MethodView):
    def post(self):
        req = request.get_json()
        provision_challs = req.get("challenges")
        provision_teams = req.get("teams")
        if not provision_challs or not provision_teams:
            return jsonify(status="failed", message="invalid body."), 400
        
        teams_query = Teams.query
        challs_query = Challenges.query
        if isinstance(provision_teams, list):
            teams_query = teams_query.where(Teams.id.in_(provision_teams))
        if isinstance(provision_challs, list):
            challs_query = challs_query.where(Challenges.id.in_(provision_challs))
        
        teams = teams_query.all()
        challenges = challs_query.all()
        if (isinstance(provision_teams, list) and len(teams) != len(provision_teams)) \
            or (isinstance(provision_challs, list) and len(challenges) != len(provision_challs)):
            return jsonify(status="failed", message="challenge or team cannot be found."), 400
        
        server_mode = get_config("SERVER_MODE")
        for team in teams:
            for chall in challenges:
                if Services.is_teamservice_exist(team.id, chall.id): continue
                if server_mode == "private": server = team.server
                else: server = chall.server
                
                try:
                    services = do_provision(team, chall, server)
                except Exception as ex:
                    error_msg = f"error when provisioning challenge id={chall.id} for team id={team.id}: {ex}"
                    app.logger.error(ex, exc_info=True)
                    return jsonify(status="failed", message=error_msg), 500

                db.session.add_all(services)
                db.session.commit()
        
        return jsonify(status="success", message="successfully provision all requested services.")

service_blueprint.add_url_rule('/provision', view_func=ServiceProvision.as_view('service_provision'))

@service_blueprint.post("/<int:challenge_id>/teams/<int:team_id>/patch")
def admin_service_patch(challenge_id, team_id):
    if not Services.is_teamservice_exist(team_id, challenge_id):
        return jsonify(status="not found", message="service not found."), 404
    
    server_mode = get_config("SERVER_MODE")
    if server_mode == "sharing":
        query_res = db.session.query(Challenges.id, Servers)\
                    .join(Servers, Servers.id == Challenges.server_id)\
                    .filter(Challenges.id == challenge_id).first()
    elif server_mode == "private":
        query_res = db.session.query(Teams.id, Servers)\
                    .join(Servers, Servers.id == Teams.server_id)\
                    .filter(Teams.id == challenge_id).first()
    server = query_res[1]

    patch_dest = os.path.join(get_service_path(team_id, challenge_id), "patch", "service.patch")
    patch_file = request.files.get("patchfile")
    if not patch_file:
        return jsonify(status="failed", message="patch file is missing."), 400    
    patch_file.save(patch_dest)
    
    do_patch(team_id, challenge_id, server)
    
    return jsonify(status="success", message="patch submitted.")


@service_blueprint.post("/<int:challenge_id>/teams/<int:team_id>/restart")
def admin_service_restart(challenge_id, team_id):
    confirm_data: dict = request.get_json()
    if not confirm_data.get("confirm"):
        return jsonify(status="bad request", message="action not confirmed"), 400
    
    if not Services.is_teamservice_exist(team_id, challenge_id):
        return jsonify(status="not found", message="service not found."), 404
    
    server_mode = get_config("SERVER_MODE")
    if server_mode == "sharing":
        query_res = db.session.query(Challenges.id, Servers)\
                    .join(Servers, Servers.id == Challenges.server_id)\
                    .filter(Challenges.id == challenge_id).first()
    elif server_mode == "private":
        query_res = db.session.query(Teams.id, Servers)\
                    .join(Servers, Servers.id == Teams.server_id)\
                    .filter(Teams.id == challenge_id).first()
    server = query_res[1]

    do_restart(team_id, challenge_id, server)
    
    return jsonify(status="success", message="restart request submitted.")


@service_blueprint.post("/<int:challenge_id>/teams/<int:team_id>/reset")
def admin_service_reset(challenge_id, team_id):
    confirm_data: dict = request.get_json()
    if not confirm_data.get("confirm"):
        return jsonify(status="bad request", message="action not confirmed"), 400
    
    if not Services.is_teamservice_exist(team_id, challenge_id):
        return jsonify(status="not found", message="service not found."), 404
    
    server_mode = get_config("SERVER_MODE")
    if server_mode == "sharing":
        query_res = db.session.query(Challenges.id, Servers)\
                    .join(Servers, Servers.id == Challenges.server_id)\
                    .filter(Challenges.id == challenge_id).first()
    elif server_mode == "private":
        query_res = db.session.query(Teams.id, Servers)\
                    .join(Servers, Servers.id == Teams.server_id)\
                    .filter(Teams.id == challenge_id).first()
    server = query_res[1]

    do_reset(team_id, challenge_id, server)
    
    return jsonify(status="success", message="reset request submitted.")
