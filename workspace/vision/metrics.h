// metrics.h
// Evaluation metrics for edge detection against BSD500 ground truth.
// All maps are binary: 0 = background, 255 = edge.
// Threshold predicted map before calling (e.g. >128 = edge).
#pragma once
#include <vector>
#include <cmath>
#include <algorithm>

struct Metrics {
    float jaccard;  // Intersection over Union (TP / (TP+FP+FN))
    float dice;     // F1 score (2*TP / (2*TP+FP+FN))
    float ssim;     // Structural similarity over 11x11 windows
};

inline Metrics compute_metrics(
    const std::vector<unsigned char>& pred,
    const std::vector<unsigned char>& gt,
    int width, int height)
{
    long tp=0, fp=0, fn=0, tn=0;
    for (int i=0; i<width*height; ++i) {
        int p = pred[i] > 128;
        int g = gt[i]   > 128;
        tp += ( p &  g);
        fp += ( p & !g);
        fn += (!p &  g);
        tn += (!p & !g);
    }
    float jaccard = (float)tp / (tp + fp + fn + 1e-6f);
    float dice    = 2.0f*tp  / (2*tp + fp + fn + 1e-6f);

    // SSIM over 11x11 windows (C1=(0.01*255)^2, C2=(0.03*255)^2)
    const double c1 = 6.5025, c2 = 58.5225;
    double ssim_sum = 0.0;
    int count = 0;
    for (int y=5; y<height-5; ++y) {
        for (int x=5; x<width-5; ++x) {
            double mu_p=0, mu_g=0;
            for (int dy=-5; dy<=5; ++dy)
                for (int dx=-5; dx<=5; ++dx) {
                    mu_p += pred[(y+dy)*width+(x+dx)];
                    mu_g += gt  [(y+dy)*width+(x+dx)];
                }
            mu_p /= 121.0; mu_g /= 121.0;
            double sp2=0, sg2=0, spg=0;
            for (int dy=-5; dy<=5; ++dy)
                for (int dx=-5; dx<=5; ++dx) {
                    double dp = pred[(y+dy)*width+(x+dx)] - mu_p;
                    double dg = gt  [(y+dy)*width+(x+dx)] - mu_g;
                    sp2 += dp*dp; sg2 += dg*dg; spg += dp*dg;
                }
            sp2 /= 120.0; sg2 /= 120.0; spg /= 120.0;
            double num = (2*mu_p*mu_g + c1) * (2*spg    + c2);
            double den = (mu_p*mu_p + mu_g*mu_g + c1) * (sp2 + sg2 + c2);
            ssim_sum += num / den;
            ++count;
        }
    }
    float ssim = (count > 0) ? (float)(ssim_sum / count) : 0.0f;
    return {jaccard, dice, ssim};
}
