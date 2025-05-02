% Load data and skymask (as in the provided example)
lat0 = 22.3198722;
lon0 = 114.209101777778;
alt0 = 3.0;
filePath = 'navSolutions.mat';

if exist(filePath, 'file')
    navSolutions1 = load(filePath);
    mask.pr = navSolutions1.navSolutions.correctedP;
    mask.az = navSolutions1.navSolutions.az;
    mask.el = navSolutions1.navSolutions.el;
    mask.pos = navSolutions1.navSolutions.satllitePosition;
else
    error('File not found: %s', filePath);
end

disp('检查数据字段和维度:');
disp(['伪距数据维度: ', num2str(size(mask.pr))]);
disp(['卫星位置维度: ', num2str(size(mask.pos))]);
disp(['方位角维度: ', num2str(size(mask.az))]);
disp(['仰角维度: ', num2str(size(mask.el))]);

% 检查伪距是否全为NaN
if all(isnan(mask.pr(:)))
    error('错误：伪距数据全为NaN，请检查navSolutions.mat文件！');
end

% Load skymask CSV
M = readmatrix('skymask_A1_urban.csv');
mask.maskAz = M(:,1);
mask.maskEl = M(:,2);
maskElVec = nan(361,1);
for i = 1:numel(mask.maskAz)
    a = round(mod(mask.maskAz(i), 360));
    maskElVec(a+1) = mask.maskEl(i);
end
idx = find(~isnan(maskElVec));
mask.maskElVec = interp1(idx-1, maskElVec(idx), (0:360)', 'linear', 'extrap');

% WGS-84 ellipsoid
wgs84 = wgs84Ellipsoid('meters');
[x0, y0, z0] = geodetic2ecef(wgs84, lat0, lon0, alt0);

% Preallocate solution and errors
[nSat, nEpoch] = size(mask.pr);
sol = nan(nEpoch, 4);
enu_errors = nan(nEpoch, 3);

% Speed of light
c = 299792458;
skipped_epochs = 0;

for epoch = 1:nEpoch
    % 提取当前历元数据
    pr = mask.pr(:, epoch);
    valid_sats = find(~isnan(pr)); % 获取非NaN卫星的数值索引
    
    % 跳过无有效卫星的历元
    if isempty(valid_sats)
        disp(['历元 ', num2str(epoch), ' 无有效卫星']);
        continue;
    end
    
    % 提取当前历元的卫星位置矩阵
    %satPos_epoch = mask.pos(:, :, 2);
    satPos_epoch = mask.pos{epoch};
    max_row = size(satPos_epoch, 1);
    
    % 强制限制索引不超过实际存储的行数
    valid_sats = valid_sats(valid_sats <= max_row);
    
    % 提取有效卫星数据
    satPos_valid = satPos_epoch(valid_sats, :);
    az_valid = mask.az(valid_sats, epoch);
    el_valid = mask.el(valid_sats, epoch);
    pr_valid = pr(valid_sats);
    
    if any(el_valid < 0 | el_valid > 90)
        error('仰角数据异常：应在0°~90°之间');
    end

    % 使用skymask进一步筛选
    keep = false(size(pr_valid)); % 根据实际有效卫星数初始化
    for i = 1:numel(pr_valid)
        az_idx = round(mod(az_valid(i), 360));
        min_el = mask.maskElVec(az_idx + 1);
        if el_valid(i) >= min_el
            keep(i) = true;
        end
    end
    
    pr_kept = pr_valid(keep);
    satPos_kept = satPos_valid(keep, :); % 确保索引不越界
    el_kept = el_valid(keep);
    num_kept = sum(keep);
    
    disp(['--- 历元 ', num2str(epoch), ' ---']);
    disp(['初始有效卫星数: ', num2str(length(valid_sats))]);
    disp(['skymask筛选后卫星数: ', num2str(num_kept)]);
    
    if num_kept < 2
        skipped_epochs = skipped_epochs + 1;
        continue; % Skip if insufficient satellites
    end
    
    % Elevation-based weights (sine squared)
    weights = sind(el_kept).^2;
    W = diag(weights);
    
    % Initial guess (previous position or ground truth)
    x = [x0; y0; z0; 0]; % [X; Y; Z; clock_bias]
    
    % Iterate WLS
    for iter = 1:10
        dx = satPos_kept(:,1) - x(1);
        dy = satPos_kept(:,2) - x(2);
        dz = satPos_kept(:,3) - x(3);
        geo_range = sqrt(dx.^2 + dy.^2 + dz.^2);
        pred_pr = geo_range + x(4);
        res = pr_kept - pred_pr;
        
        H = [-dx./geo_range, -dy./geo_range, -dz./geo_range, ones(num_kept, 1)];
        delta_x = (H' * W * H) \ (H' * W * res);
        x = x + delta_x;
        if norm(delta_x) < 1e-3
            break;
        end
    end
    
    % Store solution
    sol(epoch, :) = x;
    
    % Convert ECEF to ENU
    [lat, lon, alt] = ecef2geodetic(wgs84, x(1), x(2), x(3));
    [e, n, u] = geodetic2enu(lat, lon, alt, lat0, lon0, alt0, wgs84);
    enu_errors(epoch, :) = [e, n, u];
    disp(enu_errors(1, 1));
end

disp(['总历元数: ', num2str(nEpoch)]);
disp(['跳过的历元数: ', num2str(skipped_epochs)]);
disp(['有效定位比例: ', num2str(1 - skipped_epochs/nEpoch)]);

num_valid_epochs = sum(~isnan(enu_errors(:,1)));
disp(['有效历元数量: ', num2str(num_valid_epochs)]);

if num_valid_epochs == 0
    error('所有历元数据无效，请检查卫星筛选条件或输入数据！');
end
% 显示前5个历元的ENU误差
disp('前5个历元的ENU误差（米）:');
disp(enu_errors(1:5, :));
% Plot results
figure;
subplot(3,1,1);
plot(enu_errors(:,1), 'r');
ylabel('East Error (m)');
title('Positioning Errors Using Skymask Filtering and WLS');
subplot(3,1,2);
plot(enu_errors(:,2), 'g');
ylabel('North Error (m)');
subplot(3,1,3);
plot(enu_errors(:,3), 'b');
ylabel('Up Error (m)');
xlabel('Epoch');